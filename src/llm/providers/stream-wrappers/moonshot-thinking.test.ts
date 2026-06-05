// Moonshot thinking wrapper tests cover outgoing provider payload normalization.
import { describe, expect, it } from "vitest";
import type { StreamFn } from "../../../agents/runtime/index.js";
import { createMoonshotThinkingWrapper } from "./moonshot-thinking.js";

async function runMoonshotThinkingWrapper(
  payload: Record<string, unknown>,
  thinkingType: "enabled" | "disabled" = "enabled",
): Promise<void> {
  const baseStreamFn: StreamFn = (_model, _context, options) => {
    options?.onPayload?.(payload, {} as never);
    return {} as ReturnType<StreamFn>;
  };
  const wrapped = createMoonshotThinkingWrapper(baseStreamFn, thinkingType);

  await wrapped({ id: "kimi-k2", provider: "moonshot" } as never, { messages: [] } as never, {});
}

describe("createMoonshotThinkingWrapper", () => {
  it("ignores unreadable thinking fields when configured thinking is provided", async () => {
    const payload: Record<string, unknown> = {};
    Object.defineProperty(payload, "thinking", {
      enumerable: true,
      configurable: true,
      get() {
        throw new Error("raw thinking getter");
      },
      set(value) {
        Object.defineProperty(payload, "thinking", {
          enumerable: true,
          configurable: true,
          writable: true,
          value,
        });
      },
    });

    await runMoonshotThinkingWrapper(payload);

    expect(payload.thinking).toEqual({ type: "enabled" });
  });

  it("removes unreadable object tool choices instead of crashing thinking cleanup", async () => {
    const toolChoice = {};
    Object.defineProperty(toolChoice, "type", {
      enumerable: true,
      get() {
        throw new Error("raw tool choice type getter");
      },
    });
    const payload = {
      thinking: { type: "enabled" },
      tool_choice: toolChoice,
    };

    await runMoonshotThinkingWrapper(payload);

    expect(Object.hasOwn(payload, "tool_choice")).toBe(false);
    expect(payload.thinking).toEqual({ type: "enabled" });
  });
});
