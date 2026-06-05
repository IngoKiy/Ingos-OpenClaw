// Moonshot thinking wrapper normalizes reasoning output from Moonshot streams.
import { normalizeOptionalLowercaseString } from "@openclaw/normalization-core/string-coerce";
import type { StreamFn } from "../../../agents/runtime/index.js";
import type { ThinkLevel } from "../../../auto-reply/thinking.js";
import { createLazyImportLoader } from "../../../shared/lazy-promise.js";
import { streamWithPayloadPatch } from "./stream-payload-utils.js";

type MoonshotThinkingType = "enabled" | "disabled";
type MoonshotThinkingKeep = "all";
const MOONSHOT_THINKING_KEEP_MODEL_ID = "kimi-k2.6";
const llmRuntimeLoader = createLazyImportLoader(() => import("openclaw/plugin-sdk/llm"));

type PayloadFieldRead = { ok: true; value: unknown } | { ok: false };

async function loadDefaultStreamFn(): Promise<StreamFn> {
  const runtime = await llmRuntimeLoader.load();
  return runtime.streamSimple;
}

function readPayloadField(record: Record<string, unknown>, key: string): PayloadFieldRead {
  try {
    return { ok: true, value: record[key] };
  } catch {
    return { ok: false };
  }
}

function setPayloadField(record: Record<string, unknown>, key: string, value: unknown): void {
  try {
    record[key] = value;
  } catch {
    // Payload compatibility is best-effort; hostile setters should not abort the turn.
  }
}

function deletePayloadField(record: Record<string, unknown>, key: string): void {
  try {
    delete record[key];
  } catch {
    // Payload compatibility is best-effort; hostile delete traps should not abort the turn.
  }
}

function normalizeMoonshotThinkingType(value: unknown): MoonshotThinkingType | undefined {
  if (typeof value === "boolean") {
    return value ? "enabled" : "disabled";
  }
  if (typeof value === "string") {
    const normalized = normalizeOptionalLowercaseString(value);
    if (!normalized) {
      return undefined;
    }
    if (["enabled", "enable", "on", "true"].includes(normalized)) {
      return "enabled";
    }
    if (["disabled", "disable", "off", "false"].includes(normalized)) {
      return "disabled";
    }
    return undefined;
  }
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const type = readPayloadField(value as Record<string, unknown>, "type");
    return type.ok ? normalizeMoonshotThinkingType(type.value) : undefined;
  }
  return undefined;
}

function normalizeMoonshotThinkingKeep(value: unknown): MoonshotThinkingKeep | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }
  const keep = readPayloadField(value as Record<string, unknown>, "keep");
  if (!keep.ok) {
    return undefined;
  }
  const keepValue = keep.value;
  if (typeof keepValue !== "string") {
    return undefined;
  }
  return normalizeOptionalLowercaseString(keepValue) === "all" ? "all" : undefined;
}

function isMoonshotToolChoiceCompatible(toolChoice: unknown): boolean {
  if (toolChoice == null || toolChoice === "auto" || toolChoice === "none") {
    return true;
  }
  if (typeof toolChoice === "object" && !Array.isArray(toolChoice)) {
    const type = readPayloadField(toolChoice as Record<string, unknown>, "type");
    if (!type.ok) {
      return false;
    }
    const typeValue = type.value;
    return typeValue === "auto" || typeValue === "none";
  }
  return false;
}

function isPinnedToolChoice(toolChoice: unknown): boolean {
  if (!toolChoice || typeof toolChoice !== "object" || Array.isArray(toolChoice)) {
    return false;
  }
  const type = readPayloadField(toolChoice as Record<string, unknown>, "type");
  if (!type.ok) {
    return false;
  }
  const typeValue = type.value;
  return typeValue === "tool" || typeValue === "function";
}

/** @deprecated Moonshot provider-owned stream helper; do not use from third-party plugins. */
export function resolveMoonshotThinkingType(params: {
  configuredThinking: unknown;
  thinkingLevel?: ThinkLevel;
}): MoonshotThinkingType | undefined {
  const configured = normalizeMoonshotThinkingType(params.configuredThinking);
  if (configured) {
    return configured;
  }
  if (!params.thinkingLevel) {
    return undefined;
  }
  return params.thinkingLevel === "off" ? "disabled" : "enabled";
}

/** @deprecated Moonshot provider-owned stream helper; do not use from third-party plugins. */
export function resolveMoonshotThinkingKeep(params: {
  configuredThinking: unknown;
}): MoonshotThinkingKeep | undefined {
  return normalizeMoonshotThinkingKeep(params.configuredThinking);
}

/** @deprecated Moonshot provider-owned stream helper; do not use from third-party plugins. */
export function createMoonshotThinkingWrapper(
  baseStreamFn: StreamFn | undefined,
  thinkingType?: MoonshotThinkingType,
  thinkingKeep?: MoonshotThinkingKeep,
): StreamFn {
  return async (model, context, options) => {
    const underlying = baseStreamFn ?? (await loadDefaultStreamFn());
    return streamWithPayloadPatch(underlying, model, context, options, (payloadObj) => {
      const thinking = readPayloadField(payloadObj, "thinking");
      let effectiveThinkingType = thinking.ok
        ? normalizeMoonshotThinkingType(thinking.value)
        : undefined;

      if (thinkingType) {
        setPayloadField(payloadObj, "thinking", { type: thinkingType });
        effectiveThinkingType = thinkingType;
      }

      const toolChoice = readPayloadField(payloadObj, "tool_choice");
      if (effectiveThinkingType === "enabled") {
        if (!toolChoice.ok) {
          deletePayloadField(payloadObj, "tool_choice");
        } else if (!isMoonshotToolChoiceCompatible(toolChoice.value)) {
          if (toolChoice.value === "required") {
            setPayloadField(payloadObj, "tool_choice", "auto");
          } else if (isPinnedToolChoice(toolChoice.value)) {
            setPayloadField(payloadObj, "thinking", { type: "disabled" });
            effectiveThinkingType = "disabled";
          } else if (
            toolChoice.value &&
            typeof toolChoice.value === "object" &&
            !Array.isArray(toolChoice.value) &&
            !readPayloadField(toolChoice.value as Record<string, unknown>, "type").ok
          ) {
            deletePayloadField(payloadObj, "tool_choice");
          }
        }
      }

      const modelValue = readPayloadField(payloadObj, "model");
      const finalThinking = readPayloadField(payloadObj, "thinking");
      const isKeepCapableModel =
        modelValue.ok && modelValue.value === MOONSHOT_THINKING_KEEP_MODEL_ID;
      if (finalThinking.ok && finalThinking.value && typeof finalThinking.value === "object") {
        const thinkingObj = finalThinking.value as Record<string, unknown>;
        const keep = readPayloadField(thinkingObj, "keep");
        if (isKeepCapableModel && effectiveThinkingType === "enabled" && thinkingKeep === "all") {
          setPayloadField(thinkingObj, "keep", "all");
        } else if (keep.ok) {
          deletePayloadField(thinkingObj, "keep");
        }
      }
    });
  };
}
