import type { ExtensionAPI, ProviderModelConfig } from "@oh-my-pi/pi-coding-agent";

const DEFAULT_ENDPOINT = "http://127.0.0.1:3425";
const EFFORTS = ["minimal", "low", "medium", "high", "xhigh", "max"] as const;

type MagpieCredentials = { endpoint: string; apiKey: string };

type MagpieModel = {
	id: string;
	display_name?: string;
	reasoning?: boolean;
	supported_reasoning_levels?: { effort: string }[];
	context_window?: number;
	max_output_tokens?: number;
	modalities?: { input?: string[] };
	native_endpoints?: string[];
};

function endpointUrl(input: string): string {
	const url = new URL(input.trim() || DEFAULT_ENDPOINT);
	if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
		throw new Error("Use an HTTP(S) Magpie endpoint without credentials, a query, or a fragment.");
	}
	return url.toString().replace(/\/+$/, "").replace(/\/v1$/, "");
}

function modelConfig(model: MagpieModel, endpoint: string): ProviderModelConfig & { baseUrl: string } {
	const native = model.native_endpoints ?? [];
	const api = native.includes("/v1/responses")
		? "openai-responses"
		: native.includes("/v1/messages")
			? "anthropic-messages"
			: "openai-completions";
	const efforts = EFFORTS.filter(effort => model.supported_reasoning_levels?.some(level => level.effort === effort));
	const context = model.context_window;
	const output = model.max_output_tokens;
	const contextWindow = typeof context === "number" && Number.isFinite(context) && context > 0 ? context : 128_000;
	const maxTokens = typeof output === "number" && Number.isFinite(output) && output > 0 ? output : 16_384;
	return {
		id: model.id,
		name: model.display_name || model.id,
		api,
		baseUrl: api === "anthropic-messages" ? endpoint : `${endpoint}/v1`,
		reasoning: model.reasoning === true || efforts.length > 0,
		thinking: efforts.length > 0 ? { mode: api === "anthropic-messages" ? "budget" : "effort", efforts } : undefined,
		input: model.modalities?.input?.includes("image") ? ["text", "image"] : ["text"],
		// The gateway catalog has no prices; zero means unreported, not free.
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		contextWindow,
		maxTokens: Math.min(maxTokens, contextWindow),
	};
}

export default function magpie(pi: ExtensionAPI) {
	pi.registerProvider("magpie", {
		headers: { "User-Agent": "omp" },
		oauth: {
			name: "Magpie",
			async login(callbacks) {
				const endpoint = endpointUrl(await callbacks.onPrompt({
					message: `Magpie endpoint (default: ${DEFAULT_ENDPOINT})`,
					placeholder: DEFAULT_ENDPOINT,
					allowEmpty: true,
				}));
				const key = (await callbacks.onPrompt({
					message: "Magpie API key",
					placeholder: "sk-magpie-key-...",
					secret: true,
				})).trim();
				if (!key) throw new Error("A Magpie API key is required.");
				callbacks.signal?.throwIfAborted();
				return {
					// Discovery peeks at access directly; inference calls getApiKey.
					access: JSON.stringify({ endpoint, apiKey: key } satisfies MagpieCredentials),
					refresh: "",
					expires: Number.MAX_SAFE_INTEGER,
					accountId: "magpie",
				};
			},
			getApiKey(credentials) {
				return (JSON.parse(credentials.access) as MagpieCredentials).apiKey;
			},
		},
		async fetchDynamicModels(access) {
			if (!access) return [];
			const { endpoint, apiKey } = JSON.parse(access) as MagpieCredentials;
			const response = await fetch(`${endpoint}/v1/models`, {
				headers: { Authorization: `Bearer ${apiKey}`, "User-Agent": "omp" },
				signal: AbortSignal.timeout(15_000),
				redirect: "error",
			});
			if (!response.ok) throw new Error(`Magpie model discovery failed (HTTP ${response.status}).`);
			const catalog = await response.json() as { data?: MagpieModel[] };
			if (!Array.isArray(catalog.data) || catalog.data.some(model => !model || typeof model.id !== "string" || !model.id)) {
				throw new Error("Magpie returned an invalid model catalog.");
			}
			return catalog.data.map(model => modelConfig(model, endpoint));
		},
	});
}
