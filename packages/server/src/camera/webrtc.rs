use super::{configure_camera_decoder, decode_camera_frame};
use crate::error::AppError;
use bytes::{BufMut, Bytes, BytesMut};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::time;
use tracing::{info, warn};
use webrtc::api::interceptor_registry::register_default_interceptors;
use webrtc::api::media_engine::{MediaEngine, MIME_TYPE_H264};
use webrtc::api::APIBuilder;
use webrtc::data_channel::data_channel_message::DataChannelMessage;
use webrtc::data_channel::RTCDataChannel;
use webrtc::interceptor::registry::Registry;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::rtcp::payload_feedbacks::picture_loss_indication::PictureLossIndication;
use webrtc::rtp::packet::Packet;
use webrtc::rtp_transceiver::rtp_codec::{
    RTCRtpCodecCapability, RTCRtpCodecParameters, RTPCodecType,
};
use webrtc::track::track_remote::TrackRemote;

const CAMERA_DATA_CHANNEL_LABEL: &str = "simdeck-camera";
const H264_FMTP_LINES: [&str; 3] = [
    "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c1f",
    "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d001f",
    "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
];
const FAST_ICE_GATHER_TIMEOUT: Duration = Duration::from_millis(250);
const FULL_ICE_GATHER_TIMEOUT: Duration = Duration::from_secs(3);
const REORDER_WINDOW_PACKETS: usize = 8;
const PLI_INTERVAL: Duration = Duration::from_millis(250);
const MAX_FRAME_BYTES: usize = 2 * 1024 * 1024 - 6;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CameraWebRtcOffer {
    pub client_id: String,
    pub sdp: String,
    #[serde(rename = "type")]
    pub kind: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CameraWebRtcAnswer {
    pub sdp: String,
    #[serde(rename = "type")]
    pub kind: String,
}

struct CameraWebRtcSession {
    cancelled: Arc<AtomicBool>,
    peer_connection: Arc<webrtc::peer_connection::RTCPeerConnection>,
    metrics: Arc<CameraWebRtcMetrics>,
}

#[derive(Default)]
struct CameraWebRtcMetrics {
    connected: AtomicBool,
    rtp_packets: AtomicU64,
    rtp_bytes: AtomicU64,
    lost_packets: AtomicU64,
    reordered_packets: AtomicU64,
    assembled_frames: AtomicU64,
    published_frames: AtomicU64,
    dropped_frames: AtomicU64,
    dependency_drops: AtomicU64,
    native_errors: AtomicU64,
    pli_count: AtomicU64,
    pli_recoveries: AtomicU64,
    last_pli_recovery_ms: AtomicU64,
    maximum_pli_recovery_ms: AtomicU64,
    pending_pli: Mutex<Option<Instant>>,
    queue_high_water: AtomicU64,
    browser: Mutex<Option<CameraBrowserStats>>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct CameraBrowserStats {
    #[serde(default)]
    average_encode_time_ms: f64,
    #[serde(default)]
    bitrate: u64,
    #[serde(default)]
    buffered_bytes: u64,
    #[serde(default)]
    bytes_sent: u64,
    #[serde(default)]
    codec: String,
    #[serde(default)]
    encoded_frames_per_second: f64,
    #[serde(default)]
    input_height: u32,
    #[serde(default)]
    input_width: u32,
    #[serde(default)]
    jitter_ms: f64,
    #[serde(default)]
    key_frames_encoded: u64,
    #[serde(default)]
    output_height: u32,
    #[serde(default)]
    output_width: u32,
    #[serde(default)]
    packets_lost: i64,
    #[serde(default)]
    packets_sent: u64,
    #[serde(default)]
    quality_limitation_reason: String,
    #[serde(default)]
    round_trip_time_ms: f64,
    #[serde(default)]
    skipped_frames: u64,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "event", rename_all = "camelCase")]
enum CameraDataChannelMessage {
    Telemetry { stats: CameraBrowserStats },
    Stopping,
}

impl CameraWebRtcMetrics {
    fn record_pli(&self) {
        self.pli_count.fetch_add(1, Ordering::Relaxed);
        let mut pending = self.pending_pli.lock().unwrap();
        if pending.is_none() {
            *pending = Some(Instant::now());
        }
    }

    fn record_keyframe(&self) {
        let started = self.pending_pli.lock().unwrap().take();
        let Some(started) = started else {
            return;
        };
        let elapsed_ms = started.elapsed().as_millis().min(u64::MAX as u128) as u64;
        self.pli_recoveries.fetch_add(1, Ordering::Relaxed);
        self.last_pli_recovery_ms
            .store(elapsed_ms, Ordering::Relaxed);
        update_atomic_maximum(&self.maximum_pli_recovery_ms, elapsed_ms);
    }
}

fn apply_data_channel_message(
    message: CameraDataChannelMessage,
    metrics: &CameraWebRtcMetrics,
    cancelled: &AtomicBool,
) -> bool {
    match message {
        CameraDataChannelMessage::Telemetry { stats } => {
            *metrics.browser.lock().unwrap() = Some(stats);
            false
        }
        CameraDataChannelMessage::Stopping => {
            cancelled.store(true, Ordering::Release);
            metrics.connected.store(false, Ordering::Relaxed);
            true
        }
    }
}

fn update_atomic_maximum(target: &AtomicU64, value: u64) {
    let mut previous = target.load(Ordering::Relaxed);
    while value > previous {
        match target.compare_exchange_weak(previous, value, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return,
            Err(actual) => previous = actual,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct CameraWebRtcAttempt {
    client_id: String,
    generation: u64,
}

#[derive(Default)]
struct CameraWebRtcRegistry {
    latest_attempts: HashMap<String, CameraWebRtcAttempt>,
    next_generation: u64,
    sessions: HashMap<String, Arc<CameraWebRtcSession>>,
}

impl CameraWebRtcRegistry {
    fn begin_attempt(&mut self, udid: &str, client_id: String) -> CameraWebRtcAttempt {
        self.next_generation = self.next_generation.wrapping_add(1).max(1);
        let attempt = CameraWebRtcAttempt {
            client_id,
            generation: self.next_generation,
        };
        self.latest_attempts
            .insert(udid.to_owned(), attempt.clone());
        attempt
    }

    fn is_current_attempt(&self, udid: &str, attempt: &CameraWebRtcAttempt) -> bool {
        self.latest_attempts
            .get(udid)
            .is_some_and(|latest| latest == attempt)
    }

    fn clear_attempt_if_current(&mut self, udid: &str, attempt: &CameraWebRtcAttempt) -> bool {
        if !self.is_current_attempt(udid, attempt) {
            return false;
        }
        self.latest_attempts.remove(udid);
        self.sessions.remove(udid);
        true
    }
}

static CAMERA_WEBRTC_REGISTRY: OnceLock<Mutex<CameraWebRtcRegistry>> = OnceLock::new();

pub async fn create_answer(
    udid: String,
    payload: CameraWebRtcOffer,
) -> Result<CameraWebRtcAnswer, AppError> {
    if payload.kind != "offer" {
        return Err(AppError::bad_request(
            "Camera WebRTC payload must include type `offer`.",
        ));
    }
    let client_id = payload.client_id.trim().to_owned();
    if client_id.is_empty() {
        return Err(AppError::bad_request(
            "Camera WebRTC payload must include clientId.",
        ));
    }
    if !payload.sdp.to_ascii_lowercase().contains("h264/90000") {
        return Err(AppError::bad_request(
            "This browser did not offer H.264 camera video.",
        ));
    }
    let attempt = registry().lock().unwrap().begin_attempt(&udid, client_id);

    let mut media_engine = MediaEngine::default();
    for (index, sdp_fmtp_line) in H264_FMTP_LINES.iter().enumerate() {
        media_engine
            .register_codec(
                RTCRtpCodecParameters {
                    capability: RTCRtpCodecCapability {
                        mime_type: MIME_TYPE_H264.to_owned(),
                        clock_rate: 90_000,
                        channels: 0,
                        sdp_fmtp_line: (*sdp_fmtp_line).to_owned(),
                        rtcp_feedback: crate::transport::webrtc::h264_rtcp_feedback(),
                    },
                    payload_type: 96 + index as u8,
                    ..Default::default()
                },
                RTPCodecType::Video,
            )
            .map_err(|err| AppError::internal(format!("register camera H.264 codec: {err}")))?;
    }
    let mut interceptor_registry = Registry::new();
    interceptor_registry = register_default_interceptors(interceptor_registry, &mut media_engine)
        .map_err(|err| {
        AppError::internal(format!("register camera WebRTC interceptors: {err}"))
    })?;
    let api = APIBuilder::new()
        .with_media_engine(media_engine)
        .with_interceptor_registry(interceptor_registry)
        .build();
    let peer_connection = Arc::new(
        api.new_peer_connection(RTCConfiguration {
            ice_servers: crate::transport::webrtc::ice_servers(),
            ice_transport_policy: crate::transport::webrtc::ice_transport_policy(),
            ..Default::default()
        })
        .await
        .map_err(|err| AppError::internal(format!("create camera WebRTC peer: {err}")))?,
    );
    let metrics = Arc::new(CameraWebRtcMetrics::default());
    let cancelled = Arc::new(AtomicBool::new(false));

    let data_udid = udid.clone();
    let data_metrics = metrics.clone();
    let data_cancelled = cancelled.clone();
    let data_peer_connection = peer_connection.clone();
    peer_connection.on_data_channel(Box::new(move |channel: Arc<RTCDataChannel>| {
        let data_udid = data_udid.clone();
        let data_metrics = data_metrics.clone();
        let data_cancelled = data_cancelled.clone();
        let data_peer_connection = data_peer_connection.clone();
        Box::pin(async move {
            if channel.label() != CAMERA_DATA_CHANNEL_LABEL {
                return;
            }
            let message_metrics = data_metrics.clone();
            let message_udid = data_udid.clone();
            let message_cancelled = data_cancelled.clone();
            let message_peer_connection = data_peer_connection.clone();
            channel.on_message(Box::new(move |message: DataChannelMessage| {
                let data_metrics = message_metrics.clone();
                let data_udid = message_udid.clone();
                let data_cancelled = message_cancelled.clone();
                let data_peer_connection = message_peer_connection.clone();
                Box::pin(async move {
                    let Ok(text) = std::str::from_utf8(&message.data) else {
                        warn!("Invalid camera telemetry bytes for {data_udid}");
                        return;
                    };
                    match serde_json::from_str::<CameraDataChannelMessage>(text) {
                        Ok(message) => {
                            if apply_data_channel_message(
                                message,
                                &data_metrics,
                                &data_cancelled,
                            ) {
                                tokio::spawn(async move {
                                    if let Err(err) = data_peer_connection.close().await {
                                        warn!(
                                            "Unable to close camera WebRTC peer for {data_udid}: {err}"
                                        );
                                    }
                                });
                            }
                        }
                        Err(err) => warn!("Invalid camera telemetry for {data_udid}: {err}"),
                    }
                })
            }));
            let ready_channel = channel.clone();
            channel.on_open(Box::new(move || {
                let ready_channel = ready_channel.clone();
                let data_udid = data_udid.clone();
                Box::pin(async move {
                    if let Err(err) = ready_channel
                        .send_text(json!({ "ready": true, "udid": data_udid }).to_string())
                        .await
                    {
                        warn!("Unable to send camera WebRTC readiness: {err}");
                    }
                })
            }));
        })
    }));

    let track_peer = peer_connection.clone();
    let track_metrics = metrics.clone();
    let track_udid = udid.clone();
    let track_cancelled = cancelled.clone();
    peer_connection.on_track(Box::new(move |track, _, _| {
        let track_peer = track_peer.clone();
        let track_metrics = track_metrics.clone();
        let track_udid = track_udid.clone();
        let track_cancelled = track_cancelled.clone();
        tokio::spawn(async move {
            receive_h264_track(
                track_udid,
                track_peer,
                track,
                track_metrics,
                track_cancelled,
            )
            .await;
        });
        Box::pin(async {})
    }));

    let state_metrics = metrics.clone();
    let state_udid = udid.clone();
    let state_attempt = attempt.clone();
    peer_connection.on_peer_connection_state_change(Box::new(move |state| {
        let state_metrics = state_metrics.clone();
        let state_udid = state_udid.clone();
        let state_attempt = state_attempt.clone();
        Box::pin(async move {
            let connected = state == RTCPeerConnectionState::Connected;
            state_metrics.connected.store(connected, Ordering::Relaxed);
            info!("Camera WebRTC peer state for {state_udid}: {state}");
            if matches!(
                state,
                RTCPeerConnectionState::Failed | RTCPeerConnectionState::Closed
            ) {
                registry()
                    .lock()
                    .unwrap()
                    .clear_attempt_if_current(&state_udid, &state_attempt);
            }
        })
    }));

    let fast_gather = payload.sdp.lines().any(|line| {
        line.starts_with("a=candidate:") && line.split_whitespace().any(|part| part == "host")
    });
    let offer = RTCSessionDescription::offer(payload.sdp)
        .map_err(|err| AppError::bad_request(format!("invalid camera WebRTC offer: {err}")))?;
    peer_connection
        .set_remote_description(offer)
        .await
        .map_err(|err| AppError::bad_request(format!("set camera WebRTC offer: {err}")))?;
    let answer = peer_connection
        .create_answer(None)
        .await
        .map_err(|err| AppError::internal(format!("create camera WebRTC answer: {err}")))?;
    let mut gather_complete = peer_connection.gathering_complete_promise().await;
    peer_connection
        .set_local_description(answer)
        .await
        .map_err(|err| AppError::internal(format!("set camera WebRTC answer: {err}")))?;
    let gather_timeout = if fast_gather {
        FAST_ICE_GATHER_TIMEOUT
    } else {
        FULL_ICE_GATHER_TIMEOUT
    };
    let gather_result = time::timeout(gather_timeout, gather_complete.recv()).await;
    let mut local_description = peer_connection
        .local_description()
        .await
        .ok_or_else(|| AppError::internal("Camera WebRTC answer was not set."))?;
    if gather_result.is_err()
        && !local_description
            .sdp
            .lines()
            .any(|line| line.starts_with("a=candidate:"))
    {
        let _ = time::timeout(FULL_ICE_GATHER_TIMEOUT, gather_complete.recv()).await;
        local_description = peer_connection
            .local_description()
            .await
            .ok_or_else(|| AppError::internal("Camera WebRTC answer was not set."))?;
    }

    let session = Arc::new(CameraWebRtcSession {
        cancelled: cancelled.clone(),
        peer_connection: peer_connection.clone(),
        metrics,
    });
    let previous = {
        let mut registry = registry().lock().unwrap();
        if !registry.is_current_attempt(&udid, &attempt) {
            None
        } else {
            Some(registry.sessions.insert(udid.clone(), session.clone()))
        }
    };
    let Some(previous) = previous else {
        cancelled.store(true, Ordering::Release);
        let _ = peer_connection.close().await;
        return Err(AppError::conflict(
            "Camera WebRTC offer was superseded by a newer request.",
        ));
    };
    if let Some(previous) = previous {
        previous.cancelled.store(true, Ordering::Release);
        let _ = previous.peer_connection.close().await;
    }
    Ok(CameraWebRtcAnswer {
        sdp: local_description.sdp,
        kind: "answer".to_owned(),
    })
}

pub async fn stop(udid: &str) {
    let session = {
        let mut registry = registry().lock().unwrap();
        registry.latest_attempts.remove(udid);
        registry.sessions.remove(udid)
    };
    if let Some(session) = session {
        session.cancelled.store(true, Ordering::Release);
        let _ = session.peer_connection.close().await;
    }
}

pub fn enrich_status(udid: &str, object: &mut Map<String, Value>) {
    let metrics = registry()
        .lock()
        .unwrap()
        .sessions
        .get(udid)
        .map(|session| session.metrics.clone());
    let Some(metrics) = metrics else {
        return;
    };
    object.insert(
        "webRtcCamera".to_owned(),
        json!({
            "connected": metrics.connected.load(Ordering::Relaxed),
            "rtpPackets": metrics.rtp_packets.load(Ordering::Relaxed),
            "rtpBytes": metrics.rtp_bytes.load(Ordering::Relaxed),
            "lostPackets": metrics.lost_packets.load(Ordering::Relaxed),
            "reorderedPackets": metrics.reordered_packets.load(Ordering::Relaxed),
            "assembledFrames": metrics.assembled_frames.load(Ordering::Relaxed),
            "publishedFrames": metrics.published_frames.load(Ordering::Relaxed),
            "droppedFrames": metrics.dropped_frames.load(Ordering::Relaxed),
            "dependencyDrops": metrics.dependency_drops.load(Ordering::Relaxed),
            "nativeErrors": metrics.native_errors.load(Ordering::Relaxed),
            "pliCount": metrics.pli_count.load(Ordering::Relaxed),
            "pliRecoveries": metrics.pli_recoveries.load(Ordering::Relaxed),
            "lastPliRecoveryMs": metrics.last_pli_recovery_ms.load(Ordering::Relaxed),
            "maximumPliRecoveryMs": metrics.maximum_pli_recovery_ms.load(Ordering::Relaxed),
            "queueHighWater": metrics.queue_high_water.load(Ordering::Relaxed),
            "browser": metrics.browser.lock().unwrap().clone(),
        }),
    );
}

fn registry() -> &'static Mutex<CameraWebRtcRegistry> {
    CAMERA_WEBRTC_REGISTRY.get_or_init(|| Mutex::new(CameraWebRtcRegistry::default()))
}

async fn receive_h264_track(
    udid: String,
    peer_connection: Arc<webrtc::peer_connection::RTCPeerConnection>,
    track: Arc<TrackRemote>,
    metrics: Arc<CameraWebRtcMetrics>,
    cancelled: Arc<AtomicBool>,
) {
    if track.kind() != RTPCodecType::Video {
        return;
    }
    let queue = Arc::new(LatestFrameQueue::default());
    let decoder_queue = queue.clone();
    let decoder_metrics = metrics.clone();
    let decoder_udid = udid.clone();
    let decoder_cancelled = cancelled.clone();
    std::thread::spawn(move || {
        decode_latest_frames(
            decoder_udid,
            decoder_queue,
            decoder_metrics,
            decoder_cancelled,
        )
    });

    let mut reorder = RtpReorderBuffer::new(REORDER_WINDOW_PACKETS);
    let mut assembler = H264FrameAssembler::default();
    let mut last_pli = Instant::now() - PLI_INTERVAL;
    while !cancelled.load(Ordering::Acquire) {
        let Ok((packet, _)) = track.read_rtp().await else {
            break;
        };
        if cancelled.load(Ordering::Acquire) {
            break;
        }
        metrics.rtp_packets.fetch_add(1, Ordering::Relaxed);
        metrics
            .rtp_bytes
            .fetch_add(packet.payload.len() as u64, Ordering::Relaxed);
        let reordered = reorder.push(packet);
        if reordered.reordered {
            metrics.reordered_packets.fetch_add(1, Ordering::Relaxed);
        }
        if reordered.lost > 0 {
            metrics
                .lost_packets
                .fetch_add(reordered.lost, Ordering::Relaxed);
            assembler.mark_loss();
        }
        for packet in reordered.packets {
            let result = assembler.push(packet);
            if let Some(frame) = result.frame {
                if frame.key_frame {
                    metrics.record_keyframe();
                }
                metrics.assembled_frames.fetch_add(1, Ordering::Relaxed);
                queue.push(frame, &metrics);
            } else if result.request_keyframe {
                metrics.dependency_drops.fetch_add(1, Ordering::Relaxed);
            }
            if result.request_keyframe && last_pli.elapsed() >= PLI_INTERVAL {
                let packet = PictureLossIndication {
                    sender_ssrc: 0,
                    media_ssrc: track.ssrc(),
                };
                if peer_connection
                    .write_rtcp(&[Box::new(packet)])
                    .await
                    .is_ok()
                {
                    metrics.record_pli();
                    last_pli = Instant::now();
                }
            }
        }
    }
    queue.close();
}

fn decode_latest_frames(
    udid: String,
    queue: Arc<LatestFrameQueue>,
    metrics: Arc<CameraWebRtcMetrics>,
    cancelled: Arc<AtomicBool>,
) {
    let mut sequence = 0u32;
    while let Some(frame) = queue.pop() {
        if cancelled.load(Ordering::Acquire) {
            break;
        }
        if let Some(config) = frame.decoder_config {
            if let Err(err) = configure_camera_decoder(&udid, &config) {
                metrics.native_errors.fetch_add(1, Ordering::Relaxed);
                warn!("Unable to configure camera H.264 decoder for {udid}: {err}");
                continue;
            }
        }
        match decode_camera_frame(
            &udid,
            frame.data,
            frame.key_frame,
            sequence,
            frame.assembled_timestamp_ns,
        ) {
            Ok(()) => {
                metrics.published_frames.fetch_add(1, Ordering::Relaxed);
            }
            Err(err) => {
                metrics.native_errors.fetch_add(1, Ordering::Relaxed);
                warn!("Unable to publish camera H.264 frame for {udid}: {err}");
            }
        }
        sequence = sequence.wrapping_add(1);
    }
}

#[derive(Default)]
struct LatestFrameQueue {
    state: Mutex<LatestFrameQueueState>,
    changed: Condvar,
}

#[derive(Default)]
struct LatestFrameQueueState {
    frame: Option<CompleteFrame>,
    closed: bool,
}

impl LatestFrameQueue {
    fn push(&self, frame: CompleteFrame, metrics: &CameraWebRtcMetrics) {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return;
        }
        if state.frame.replace(frame).is_some() {
            metrics.dropped_frames.fetch_add(1, Ordering::Relaxed);
        }
        metrics.queue_high_water.store(1, Ordering::Relaxed);
        self.changed.notify_one();
    }

    fn pop(&self) -> Option<CompleteFrame> {
        let mut state = self.state.lock().unwrap();
        loop {
            if let Some(frame) = state.frame.take() {
                return Some(frame);
            }
            if state.closed {
                return None;
            }
            state = self.changed.wait(state).unwrap();
        }
    }

    fn close(&self) {
        let mut state = self.state.lock().unwrap();
        state.closed = true;
        state.frame = None;
        self.changed.notify_all();
    }
}

struct CompleteFrame {
    data: Bytes,
    key_frame: bool,
    decoder_config: Option<Bytes>,
    assembled_timestamp_ns: u64,
}

struct H264FrameAssembler {
    timestamp: Option<u32>,
    data: BytesMut,
    fragmented_nal: Option<BytesMut>,
    key_frame: bool,
    damaged: bool,
    waiting_for_keyframe: bool,
    sps: Option<Bytes>,
    pps: Option<Bytes>,
}

impl Default for H264FrameAssembler {
    fn default() -> Self {
        Self {
            timestamp: None,
            data: BytesMut::new(),
            fragmented_nal: None,
            key_frame: false,
            damaged: false,
            waiting_for_keyframe: true,
            sps: None,
            pps: None,
        }
    }
}

struct AssemblyResult {
    frame: Option<CompleteFrame>,
    request_keyframe: bool,
}

impl H264FrameAssembler {
    fn mark_loss(&mut self) {
        self.damaged = true;
        self.waiting_for_keyframe = true;
    }

    fn push(&mut self, packet: Packet) -> AssemblyResult {
        let mut request_keyframe = false;
        if self
            .timestamp
            .is_some_and(|timestamp| timestamp != packet.header.timestamp)
        {
            if !self.data.is_empty() || self.fragmented_nal.is_some() {
                request_keyframe = true;
                self.waiting_for_keyframe = true;
            }
            self.reset_frame(packet.header.timestamp);
        } else if self.timestamp.is_none() {
            self.timestamp = Some(packet.header.timestamp);
        }

        if self.push_payload(&packet.payload).is_err() {
            self.damaged = true;
            self.waiting_for_keyframe = true;
        }
        if !packet.header.marker {
            return AssemblyResult {
                frame: None,
                request_keyframe,
            };
        }
        if self.fragmented_nal.is_some() {
            self.damaged = true;
        }
        let frame = if self.damaged || self.data.is_empty() {
            request_keyframe = true;
            self.waiting_for_keyframe = true;
            None
        } else if self.waiting_for_keyframe && !self.key_frame {
            request_keyframe = true;
            None
        } else {
            let decoder_config = if self.key_frame {
                self.decoder_config()
            } else {
                None
            };
            if self.key_frame && decoder_config.is_none() {
                request_keyframe = true;
                self.waiting_for_keyframe = true;
                None
            } else {
                if self.key_frame {
                    self.waiting_for_keyframe = false;
                }
                Some(CompleteFrame {
                    data: self.data.split().freeze(),
                    key_frame: self.key_frame,
                    decoder_config,
                    assembled_timestamp_ns: SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_nanos()
                        .min(u64::MAX as u128) as u64,
                })
            }
        };
        let next_timestamp = packet.header.timestamp.wrapping_add(1);
        self.reset_frame(next_timestamp);
        AssemblyResult {
            frame,
            request_keyframe,
        }
    }

    fn reset_frame(&mut self, timestamp: u32) {
        self.timestamp = Some(timestamp);
        self.data.clear();
        self.fragmented_nal = None;
        self.key_frame = false;
        self.damaged = false;
    }

    fn push_payload(&mut self, payload: &Bytes) -> Result<(), ()> {
        if payload.len() < 2 {
            return Err(());
        }
        match payload[0] & 0x1f {
            1..=23 => self.push_nal(payload),
            24 => {
                let mut offset = 1;
                while offset + 2 <= payload.len() {
                    let length =
                        u16::from_be_bytes([payload[offset], payload[offset + 1]]) as usize;
                    offset += 2;
                    if length == 0 || offset + length > payload.len() {
                        return Err(());
                    }
                    self.push_nal(&payload.slice(offset..offset + length))?;
                    offset += length;
                }
                if offset == payload.len() {
                    Ok(())
                } else {
                    Err(())
                }
            }
            28 => self.push_fu_a(payload),
            _ => Err(()),
        }
    }

    fn push_fu_a(&mut self, payload: &Bytes) -> Result<(), ()> {
        if payload.len() < 3 {
            return Err(());
        }
        let start = payload[1] & 0x80 != 0;
        let end = payload[1] & 0x40 != 0;
        if start {
            if self.fragmented_nal.is_some() {
                return Err(());
            }
            let mut nal = BytesMut::with_capacity(payload.len() * 2);
            nal.put_u8((payload[0] & 0xe0) | (payload[1] & 0x1f));
            nal.extend_from_slice(&payload[2..]);
            self.fragmented_nal = Some(nal);
        } else if let Some(nal) = self.fragmented_nal.as_mut() {
            nal.extend_from_slice(&payload[2..]);
        } else {
            return Err(());
        }
        if end {
            let nal = self.fragmented_nal.take().ok_or(())?.freeze();
            self.push_nal(&nal)?;
        }
        Ok(())
    }

    fn push_nal(&mut self, nal: &Bytes) -> Result<(), ()> {
        if nal.is_empty() {
            return Err(());
        }
        match nal[0] & 0x1f {
            7 => self.sps = Some(nal.clone()),
            8 => self.pps = Some(nal.clone()),
            9 => {}
            5 => {
                self.key_frame = true;
                self.append_avcc_nal(nal)?;
            }
            _ => self.append_avcc_nal(nal)?,
        }
        Ok(())
    }

    fn append_avcc_nal(&mut self, nal: &Bytes) -> Result<(), ()> {
        if self.data.len() + nal.len() + 4 > MAX_FRAME_BYTES {
            return Err(());
        }
        self.data.put_u32(nal.len() as u32);
        self.data.extend_from_slice(nal);
        Ok(())
    }

    fn decoder_config(&self) -> Option<Bytes> {
        let sps = self.sps.as_ref()?;
        let pps = self.pps.as_ref()?;
        if sps.len() < 4 || sps.len() > u16::MAX as usize || pps.len() > u16::MAX as usize {
            return None;
        }
        let mut config = BytesMut::with_capacity(sps.len() + pps.len() + 16);
        config.put_u8(1);
        config.put_u8(sps[1]);
        config.put_u8(sps[2]);
        config.put_u8(sps[3]);
        config.put_u8(0xff);
        config.put_u8(0xe1);
        config.put_u16(sps.len() as u16);
        config.extend_from_slice(sps);
        config.put_u8(1);
        config.put_u16(pps.len() as u16);
        config.extend_from_slice(pps);
        Some(config.freeze())
    }
}

struct ReorderResult {
    packets: Vec<Packet>,
    lost: u64,
    reordered: bool,
}

struct RtpReorderBuffer {
    expected: Option<u16>,
    pending: HashMap<u16, Packet>,
    window: usize,
}

impl RtpReorderBuffer {
    fn new(window: usize) -> Self {
        Self {
            expected: None,
            pending: HashMap::new(),
            window,
        }
    }

    fn push(&mut self, packet: Packet) -> ReorderResult {
        let sequence = packet.header.sequence_number;
        let expected = self.expected.get_or_insert(sequence);
        let distance = sequence.wrapping_sub(*expected);
        if distance > u16::MAX / 2 {
            return ReorderResult {
                packets: Vec::new(),
                lost: 0,
                reordered: true,
            };
        }
        let marker = packet.header.marker;
        let reordered = distance > 0;
        self.pending.entry(sequence).or_insert(packet);
        let mut packets = self.drain_contiguous();
        let mut lost = 0;
        if self.pending.len() > self.window
            || (marker && packets.last().is_none_or(|p| !p.header.marker))
        {
            if let Some(next) = self.nearest_pending_sequence() {
                let expected = self.expected.unwrap();
                lost = next.wrapping_sub(expected) as u64;
                self.expected = Some(next);
                packets.extend(self.drain_contiguous());
            }
        }
        ReorderResult {
            packets,
            lost,
            reordered,
        }
    }

    fn drain_contiguous(&mut self) -> Vec<Packet> {
        let mut packets = Vec::new();
        while let Some(expected) = self.expected {
            let Some(packet) = self.pending.remove(&expected) else {
                break;
            };
            self.expected = Some(expected.wrapping_add(1));
            packets.push(packet);
        }
        packets
    }

    fn nearest_pending_sequence(&self) -> Option<u16> {
        let expected = self.expected?;
        self.pending
            .keys()
            .copied()
            .min_by_key(|sequence| sequence.wrapping_sub(expected))
    }
}

#[cfg(test)]
mod tests {
    use super::{
        apply_data_channel_message, CameraDataChannelMessage, CameraWebRtcMetrics,
        CameraWebRtcRegistry, H264FrameAssembler, RtpReorderBuffer,
    };
    use bytes::Bytes;
    use std::sync::atomic::{AtomicBool, Ordering};
    use webrtc::rtp::header::Header;
    use webrtc::rtp::packet::Packet;

    fn packet(sequence: u16, timestamp: u32, marker: bool, payload: &[u8]) -> Packet {
        Packet {
            header: Header {
                sequence_number: sequence,
                timestamp,
                marker,
                ..Default::default()
            },
            payload: Bytes::copy_from_slice(payload),
        }
    }

    #[test]
    fn stopping_message_marks_camera_session_disconnected_and_cancelled() {
        let metrics = CameraWebRtcMetrics::default();
        metrics.connected.store(true, Ordering::Relaxed);
        let cancelled = AtomicBool::new(false);

        let close_peer =
            apply_data_channel_message(CameraDataChannelMessage::Stopping, &metrics, &cancelled);

        assert!(close_peer);
        assert!(!metrics.connected.load(Ordering::Relaxed));
        assert!(cancelled.load(Ordering::Acquire));
    }

    #[test]
    fn out_of_order_camera_offer_completion_cannot_replace_or_clear_the_latest_attempt() {
        let mut registry = CameraWebRtcRegistry::default();
        let first = registry.begin_attempt("device-a", "browser".to_owned());
        let second = registry.begin_attempt("device-a", "browser".to_owned());

        assert!(!registry.is_current_attempt("device-a", &first));
        assert!(registry.is_current_attempt("device-a", &second));
        assert!(!registry.clear_attempt_if_current("device-a", &first));
        assert!(registry.is_current_attempt("device-a", &second));
        assert!(registry.clear_attempt_if_current("device-a", &second));
    }

    #[test]
    fn assembles_avcc_keyframe_and_decoder_configuration() {
        let mut assembler = H264FrameAssembler::default();
        assert!(assembler
            .push(packet(1, 90_000, false, &[0x67, 0x42, 0xe0, 0x1f]))
            .frame
            .is_none());
        assert!(assembler
            .push(packet(2, 90_000, false, &[0x68, 0xce, 0x06, 0xe2]))
            .frame
            .is_none());
        let result = assembler.push(packet(3, 90_000, true, &[0x65, 0xaa, 0xbb]));
        let frame = result.frame.unwrap();

        assert!(frame.key_frame);
        assert_eq!(&frame.data[..], &[0, 0, 0, 3, 0x65, 0xaa, 0xbb]);
        assert!(frame.decoder_config.unwrap().len() > 12);
        assert!(!result.request_keyframe);
    }

    #[test]
    fn assembles_stap_a_parameter_sets_and_fu_a_slice() {
        let mut assembler = H264FrameAssembler::default();
        let stap = [
            0x78, 0, 4, 0x67, 0x42, 0xe0, 0x1f, 0, 4, 0x68, 0xce, 0x06, 0xe2,
        ];
        assert!(assembler
            .push(packet(1, 90_000, false, &stap))
            .frame
            .is_none());
        assert!(assembler
            .push(packet(2, 90_000, false, &[0x7c, 0x85, 0xaa]))
            .frame
            .is_none());
        let result = assembler.push(packet(3, 90_000, true, &[0x7c, 0x45, 0xbb]));

        assert_eq!(
            &result.frame.unwrap().data[..],
            &[0, 0, 0, 3, 0x65, 0xaa, 0xbb]
        );
    }

    #[test]
    fn reorders_packets_and_declares_marker_gaps_lost() {
        let mut reorder = RtpReorderBuffer::new(8);
        assert_eq!(reorder.push(packet(10, 1, false, &[1, 1])).packets.len(), 1);
        let delayed = reorder.push(packet(12, 1, false, &[1, 3]));
        assert!(delayed.packets.is_empty());
        assert!(delayed.reordered);
        let ordered = reorder.push(packet(11, 1, false, &[1, 2]));
        assert_eq!(ordered.packets.len(), 2);
        let loss = reorder.push(packet(14, 1, true, &[1, 4]));
        assert_eq!(loss.lost, 1);
        assert_eq!(loss.packets.len(), 1);
    }
}
