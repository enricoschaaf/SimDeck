use serde_json::Value;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::broadcast;

const DEVICE_EVENT_CAPACITY: usize = 128;

#[derive(Clone, Default)]
pub struct DeviceEventHub {
    senders: Arc<Mutex<HashMap<String, broadcast::Sender<Value>>>>,
}

impl DeviceEventHub {
    pub fn subscribe(&self, udid: &str) -> broadcast::Receiver<Value> {
        self.sender(udid).subscribe()
    }

    pub fn publish(&self, udid: &str, event: Value) {
        let _ = self.sender(udid).send(event);
    }

    fn sender(&self, udid: &str) -> broadcast::Sender<Value> {
        let mut senders = self
            .senders
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        senders
            .entry(udid.to_owned())
            .or_insert_with(|| broadcast::channel(DEVICE_EVENT_CAPACITY).0)
            .clone()
    }
}

#[cfg(test)]
mod tests {
    use super::DeviceEventHub;
    use serde_json::json;

    #[tokio::test]
    async fn events_are_isolated_by_simulator() {
        let events = DeviceEventHub::default();
        let mut first = events.subscribe("first");
        let mut second = events.subscribe("second");

        events.publish("first", json!({ "type": "file.created" }));

        assert_eq!(first.recv().await.unwrap()["type"], "file.created");
        assert!(second.try_recv().is_err());
    }
}
