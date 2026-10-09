import { YAML } from "bun";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ProviderModelConfig } from "@oh-my-pi/pi-coding-agent";

const EFFORTS = ["minimal", "low", "medium", "high", "xhigh", "max"] as const;

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
	const url = new URL(input.trim());
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

export default async function magpie(pi: ExtensionAPI) {
	const configPath = join(homedir(), ".omp/agent/magpie.yaml");
	const config = YAML.parse(await readFile(configPath, "utf8"));
	if (
		!config || typeof config !== "object" ||
		!("endpoint" in config) || typeof config.endpoint !== "string" || !config.endpoint.trim() ||
		!("api_key" in config) || typeof config.api_key !== "string" || !config.api_key.trim()
	) {
		throw new Error(`Magpie configuration ${configPath} requires non-empty endpoint and api_key fields.`);
	}
	const endpoint = endpointUrl(config.endpoint);
	let notify: ((message: string) => void) | undefined;
	let pendingWarning: string | undefined;
	let lastWarning: string | undefined;
	pi.on("session_start", (_event, ctx) => {
		notify = ctx.hasUI ? message => ctx.ui.notify(message, "warning") : undefined;
		if (notify && pendingWarning) {
			notify(pendingWarning);
			pendingWarning = undefined;
		}
	});
	pi.on("session_shutdown", () => {
		notify = undefined;
	});
	pi.registerProvider("magpie", {
		apiKey: config.api_key.trim(),
		headers: { "User-Agent": "omp" },
		async fetchDynamicModels(apiKey) {
			if (!apiKey) return [];
			let failure = "connection error";
			try {
				const response = await fetch(`${endpoint}/v1/models`, {
					headers: { Authorization: `Bearer ${apiKey}`, "User-Agent": "omp" },
					signal: AbortSignal.timeout(15_000),
					redirect: "error",
				});
				failure = `HTTP ${response.status}`;
				if (!response.ok) throw new Error(`Magpie model discovery failed (${failure}).`);
				failure = "invalid model catalog";
				const catalog = await response.json() as { data?: MagpieModel[] };
				if (!Array.isArray(catalog.data) || catalog.data.some(model => !model || typeof model.id !== "string" || !model.id)) {
					throw new Error("Magpie returned an invalid model catalog.");
				}
				const models = catalog.data.map(model => modelConfig(model, endpoint));
				pendingWarning = undefined;
				lastWarning = undefined;
				return models;
			} catch (error) {
				const code = error && typeof error === "object" && "code" in error ? error.code : undefined;
				const reason = typeof code === "string" && /^[A-Z][A-Z0-9_]{0,63}$/.test(code)
					? code
					: error instanceof Error && error.name === "TimeoutError" ? "timeout after 15 seconds" : failure;
				const message = `Magpie model discovery failed (${reason}). Check the endpoint host/port and API key in ~/.omp/agent/magpie.yaml, then refresh models.`;
				if (message !== lastWarning) {
					lastWarning = message;
					if (notify) {
						notify(message);
					} else {
						console.warn(`Warning: ${message}`);
						pendingWarning = message;
					}
				}
				throw error;
			}
		},
	});
}
