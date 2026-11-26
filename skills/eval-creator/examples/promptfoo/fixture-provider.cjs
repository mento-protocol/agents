// Fictional saved outputs only. This provider never calls a model or network.
const demo = require("../review-demo.json");

module.exports = class FixtureProvider {
  constructor(options) {
    this.variant = demo.variants.find((v) => v.id === options.config.variant);
    if (!this.variant) throw new Error("Unknown fictional variant");
  }

  id() {
    return `fictional-review:${this.variant.id}`;
  }

  async callApi(prompt, context) {
    const row = this.variant.results.find(
      (r) => r.case_id === context.vars.case_id,
    );
    if (!row) throw new Error("Missing fictional case");
    const count = this.variant.results.length;
    const index = this.variant.results.indexOf(row);
    const share = (field) =>
      Math.floor(this.variant.usage[field] / count) +
      (index < this.variant.usage[field] % count ? 1 : 0);
    const usage = {
      prompt: share("input_tokens"),
      completion: share("output_tokens"),
      cached: share("cached_input_tokens"),
      latencyMs: (this.variant.usage.seconds * 1000) / count,
    };
    return {
      output: row.evidence,
      latencyMs: usage.latencyMs,
      tokenUsage: {
        prompt: usage.prompt,
        completion: usage.completion,
        cached: usage.cached,
        total: usage.prompt + usage.completion,
      },
      metadata: {
        demonstration: true,
        repeatIndex: context.repeatIndex,
        // Preserve known fixture values before Promptfoo can add default zeros.
        evalCreator: { usage: { ...usage } },
        fixtureScores: Object.fromEntries(
          demo.metrics.map((m) => [m.label, row.scores[m.id]]),
        ),
        note: "Fictional outputs, grades, token counts and latency. No model executed.",
      },
    };
  }
};
