import type { ExtensionAPI, ProviderModelConfig } from "@oh-my-pi/pi-coding-agent";

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

// omp's Magpie gateway extension: it registers the gateway as a provider and
// puts search on the requests that go to it. The gateway's public catalog
// supplies native APIs, context windows and thinking levels; omp's local
// settings and models stay user-owned. Consumers set PI_MAGPIE_URL: loopback on
// the gateway host, and the gateway's fully qualified MagicDNS name elsewhere,
// because the resolver does not expand the bare name below.
export default function (pi: ExtensionAPI) {
  const gateway = (process.env.PI_MAGPIE_URL ?? "http://box:3425").replace(/\/$/, "");
  const discover = async (): Promise<ProviderModelConfig[]> => {
    const response = await fetch(`${gateway}/v1/models`, {
      headers: { Authorization: "Bearer magpie", "User-Agent": "pi-magpie/1" },
      signal: AbortSignal.timeout(5000),
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

  // Loading must not wait on the gateway: it is a tailnet service, so omp can
  // start before sing-box, tailnet DNS or magpie itself is ready. Register the
  // provider with no static roster; omp calls fetchDynamicModels to discover and
  // cache the catalog once the gateway answers, so an unreachable gateway never
  // blocks extension loading or delays a sibling extension's registration. A
  // session start reports a gateway that is still unreachable.
  pi.registerProvider("magpie", {
    name: "Magpie", baseUrl: `${gateway}/v1`, api: "openai-completions", apiKey: "magpie",
    models: [],
    // omp refreshes a provider's list through fetchDynamicModels. Pi 1.0 named
    // this refreshModels, which exists in omp only on the session, not here.
    fetchDynamicModels: () => discover(),
  });

  pi.on("session_start", (_event, ctx) => {
    if (ctx.agent.kind !== "main") return;
    // Probe without delaying the session; only a failure needs to surface.
    void discover().catch((error: unknown) => {
      ctx.ui.notify(
        `Magpie is unreachable at ${gateway}: ${error instanceof Error ? error.message : String(error)}`,
        "warning",
      );
    });
  });

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
