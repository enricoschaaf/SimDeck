import { afterEach, describe, expect, it, vi } from "vitest";

import {
  SemanticKeyboardBatcher,
  SemanticKeyboardTranslator,
  type KeyboardEventLike,
} from "./semanticKeyboard";

function keyboardEvent(
  overrides: Partial<KeyboardEventLike>,
): KeyboardEventLike {
  return {
    altKey: false,
    code: "",
    ctrlKey: false,
    key: "",
    metaKey: false,
    shiftKey: false,
    ...overrides,
  };
}

function keyboardHarness() {
  const keys: Array<{ keyCode: number; modifiers: number }> = [];
  const text: string[] = [];
  const batcher = new SemanticKeyboardBatcher({
    delayMs: 16,
    onKey: (payload) => keys.push(payload),
    onText: (value) => text.push(value),
  });
  return {
    batcher,
    keys,
    text,
    translator: new SemanticKeyboardTranslator(batcher),
  };
}

afterEach(() => vi.useRealTimers());

describe("SemanticKeyboardTranslator", () => {
  it("lets the browser resolve printable keys instead of sending physical HID", () => {
    const { keys, translator } = keyboardHarness();

    expect(translator.keyDown(keyboardEvent({ code: "KeyQ", key: "a" }))).toBe(
      false,
    );
    expect(keys).toEqual([]);
  });

  it("treats AltGr and Option output as semantic text", () => {
    const { keys, translator } = keyboardHarness();

    expect(
      translator.keyDown(
        keyboardEvent({
          altKey: true,
          code: "Digit0",
          ctrlKey: true,
          key: "@",
        }),
      ),
    ).toBe(false);
    expect(keys).toEqual([]);
  });

  it("flushes semantic text before navigation HID", () => {
    const operations: string[] = [];
    const batcher = new SemanticKeyboardBatcher({
      delayMs: 16,
      onKey: ({ keyCode }) => operations.push(`key:${keyCode}`),
      onText: (value) => operations.push(`text:${value}`),
    });
    const translator = new SemanticKeyboardTranslator(batcher);
    translator.beforeInput("insertText", "é");

    expect(
      translator.keyDown(
        keyboardEvent({ code: "ArrowLeft", key: "ArrowLeft" }),
      ),
    ).toBe(true);
    expect(operations).toEqual(["text:é", "key:80"]);
  });

  it("batches browser text without waiting for a typing pause", () => {
    vi.useFakeTimers();
    const { text, translator } = keyboardHarness();

    translator.beforeInput("insertText", "a");
    vi.advanceTimersByTime(8);
    translator.beforeInput("insertText", "b");
    vi.advanceTimersByTime(8);

    expect(text).toEqual(["ab"]);
  });

  it("commits composed Unicode once", () => {
    vi.useFakeTimers();
    const { text, translator } = keyboardHarness();
    translator.compositionStart();

    expect(translator.beforeInput("insertCompositionText", "é", true)).toBe(
      false,
    );
    expect(translator.compositionEnd("é")).toBe(true);
    expect(translator.beforeInput("insertText", "é")).toBe(true);
    vi.runAllTimers();

    expect(text).toEqual(["é"]);
  });

  it("uses semantic text for paste rather than sending Command-V HID", () => {
    vi.useFakeTimers();
    const { keys, text, translator } = keyboardHarness();

    expect(
      translator.keyDown(
        keyboardEvent({ code: "KeyV", key: "v", metaKey: true }),
      ),
    ).toBe(false);
    expect(translator.paste("élise@example.com")).toBe(true);
    vi.runAllTimers();

    expect(keys).toEqual([]);
    expect(text).toEqual(["élise@example.com"]);
  });
});
