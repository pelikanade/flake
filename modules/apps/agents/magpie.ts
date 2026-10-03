import type { ExtensionAPI, ProviderModelConfig } from "@earendil-works/pi-coding-agent";

interface GatewayModel {
  id: string;
  display_name?: string;
  magpie_label?: string;
  native_endpoints?: string[];
  context_window?: number;
  max_output_tokens?: number;
  reasoning?: boolean;
  supported_reasoning_levels?: { effort: string }[];
  modalities?: { input?: ("text" | "image")[] };
}

// Pi's Magpie gateway extension: it registers the gateway as a provider and
// puts search on the requests that go to it. The gateway's public catalog
// supplies native APIs, context windows and thinking levels; Pi's local
// settings and models.json stay user-owned. Magpie runs on box, and a host that
// runs its own gateway sets PI_MAGPIE_URL.
export default async function (pi: ExtensionAPI) {
  const gateway = (process.env.PI_MAGPIE_URL ?? "http://box:3425").replace(/\/$/, "");
  const discover = async (signal?: AbortSignal): Promise<ProviderModelConfig[]> => {
    const response = await fetch(`${gateway}/v1/models`, {
      headers: { Authorization: "Bearer magpie", "User-Agent": "pi-magpie/1" },
      signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(5000)]) : AbortSignal.timeout(5000),
    });
    if (!response.ok) throw new Error(`Magpie catalog returned HTTP ${response.status}`);
    const catalog = await response.json() as { data: GatewayModel[] };
    return catalog.data.map((model) => {
      const endpoints = model.native_endpoints ?? [];
      const api = endpoints.includes("/v1/responses") ? "openai-responses"
        : endpoints.includes("/v1/messages") ? "anthropic-messages" : "openai-completions";
      const contextWindow = model.context_window || 128000;
      const efforts = model.supported_reasoning_levels?.map((level) => level.effort) ?? [];
      const thinkingLevelMap = efforts.length ? Object.fromEntries(
        ["off", "minimal", "low", "medium", "high", "xhigh", "max"].map((level) => {
          const effort = level === "off" ? "none" : level;
          return [level, efforts.includes(effort) ? effort : null];
        }),
      ) : undefined;
      if (api === "anthropic-messages" && thinkingLevelMap?.off === null) delete thinkingLevelMap.off;
      return {
        id: model.id,
        name: model.magpie_label ?? model.display_name ?? model.id,
        api,
        baseUrl: api === "anthropic-messages" ? gateway : `${gateway}/v1`,
        reasoning: model.reasoning ?? efforts.length > 0,
        input: model.modalities?.input ?? ["text"],
        contextWindow,
        maxTokens: Math.min(model.max_output_tokens || 16384, contextWindow),
        thinkingLevelMap,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      } as ProviderModelConfig;
    });
  };

  // The gateway is a tailnet service, so Pi can start before sing-box, tailnet
  // DNS or magpie itself is ready. Register the provider with no models instead
  // of failing the whole extension: refreshModels fills the list once the
  // gateway answers, and a session start says what went wrong.
  let startupError: string | undefined;
  const models = await discover().catch((error: unknown) => {
    startupError = error instanceof Error ? error.message : String(error);
    return [] as ProviderModelConfig[];
  });

  pi.registerProvider("magpie", {
    name: "Magpie", baseUrl: `${gateway}/v1`, api: "openai-completions", apiKey: "magpie",
    models,
    refreshModels: (context) => discover(context.signal),
  });

  if (startupError) {
    pi.on("session_start", async (_event, ctx) => {
      try {
        await discover();
      } catch {
        ctx.ui.notify(
          `Magpie is unreachable at ${gateway}: ${startupError}`,
          "warning",
        );
      }
    });
  }

  // Magpie runs the server-side search tool; Pi retains its ordinary tools.
  pi.on("before_provider_request", (event, ctx) => {
    if (ctx.model?.provider !== "magpie") return;
    const payload = event.payload as Record<string, unknown>;
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) return;
    if (ctx.model.api === "openai-completions") {
      return { ...payload, web_search_options: payload.web_search_options ?? {} };
    }
    const tools = payload.tools ?? [];
    if (!Array.isArray(tools) || tools.some((tool) => tool.type?.startsWith("web_search"))) return;
    if (ctx.model.api === "openai-responses") {
      return { ...payload, tools: [...tools, { type: "web_search" }] };
    }
    if (ctx.model.api === "anthropic-messages") {
      return { ...payload, tools: [...tools, { type: "web_search_20250305", name: "web_search", max_uses: 5 }] };
    }
  });
}
