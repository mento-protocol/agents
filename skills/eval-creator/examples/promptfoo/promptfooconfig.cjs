const path = require("node:path");
const fs = require("node:fs");
const crypto = require("node:crypto");
const demo = require("../review-demo.json");

module.exports = {
  description: "Fictional review comparison. No live model execution.",
  sharing: false,
  // The prefix preserves this public digest through Promptfoo's secret sanitizer.
  metadata: {
    evalCreator: {
      brief_sha256:
        "sha256:" +
        crypto
          .createHash("sha256")
          .update(fs.readFileSync(path.join(__dirname, "../review-demo.json")))
          .digest("hex"),
    },
  },
  prompts: ["{{input}}"],
  providers: demo.variants.map((v) => ({
    id: `file://${path.join(__dirname, "fixture-provider.cjs")}`,
    label: v.label,
    config: { variant: v.id },
  })),
  tests: demo.dataset.cases.map((c) => ({
    description: c.title,
    vars: { case_id: c.id, input: c.input },
    metadata: { case_id: c.id, demonstration: true },
  })),
  defaultTest: {
    assert: [
      {
        type: "javascript",
        weight: 1,
        value: `const scores = context.providerResponse.metadata.fixtureScores;
const correct = scores[${JSON.stringify(demo.metrics.find((m) => m.id === "correct").label)}];
return { pass: correct === 1, score: correct,
  namedScores: scores, reason: 'Fictional saved grades; aggregate pass is not a quality verdict.' };`,
      },
    ],
  },
  evaluateOptions: {
    cache: false,
    repeat: 1,
    maxConcurrency: 1,
    timeoutMs: 5000,
    maxEvalTimeMs: 30000,
  },
};
