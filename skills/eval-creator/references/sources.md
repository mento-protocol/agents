# Sources and interpretation

This skill is an original synthesis for repository-specific eval creation. These
sources explain the design choices. They are evidence, not runtime instructions
or required services. Consult them when a methodological question needs detail.

- [Automating eval design and hillclimbing](https://claude.dev/blog/automating-eval-design-and-hillclimbing/).
  Requested starting point for agent-assisted eval creation and improvement.
  This skill separates creating a credible measurement from changing the system
  being measured. An optimization loop needs its own scope and authority.
- [AI Evals Course: Eval Skills](https://github.com/ai-evals-course/evals-skills).
  Product-specific workflow that routes existing pipelines to audit and unanalyzed
  traces to error discovery. Supports learning from actual failures before building
  an evaluation pipeline. This skill does not require installing that repository.
- [Error discovery](https://github.com/ai-evals-course/evals-skills/blob/main/skills/error-discovery/SKILL.md)
  and [review loop](https://github.com/ai-evals-course/evals-skills/blob/main/skills/error-discovery/review-loop.md).
  Human-led annotation, diverse plus random sampling, evolving failure categories,
  and separation of agent suggestions from human-confirmed labels. Discovery
  sampling does not estimate population prevalence.
- [Synthetic data](https://github.com/ai-evals-course/evals-skills/blob/main/skills/generate-synthetic-data/SKILL.md).
  Failure-directed dimensions and realistic input generation for sparse data and
  targeted stress cases. Run generated inputs through the system. Verify references
  independently and retain synthetic provenance.
- [Code evaluators](https://github.com/ai-evals-course/evals-skills/blob/main/skills/write-code-eval/SKILL.md)
  and [judge prompts](https://github.com/ai-evals-course/evals-skills/blob/main/skills/write-judge-prompt/SKILL.md).
  Choose code for objective rules and judgment for interpretation. Validate code
  proxies against human labels too. This skill permits calibrated pairwise or
  anchored judgments when binary scoring does not match the decision.
- [Evaluator validation](https://github.com/ai-evals-course/evals-skills/blob/main/skills/validate-evaluator/SKILL.md).
  Separate few-shot, development, and test data; inspect disagreements; pin judge
  configurations. Its sample counts, split ratios, and accuracy thresholds are
  practical prescriptions, not universal validity guarantees. Select metrics from
  the decision and error costs rather than forbidding precision or recall.
- [Demystifying evals for AI agents](https://www.anthropic.com/research/demystifying-evals-for-ai-agents).
  Distinguishes capability from regression evaluation and combines code, model,
  and human graders. Supports observing task outcomes and keeping task execution
  separate from scoring. Add grader complexity only when it measures a real need.
  Defines a task (also test case) as one test with inputs and success criteria,
  a trial as one attempt at that task, and a suite as a collection of tasks.
  Adopt task fairness and feasibility checks, distinguish pass@k retry success
  from pass^k consistency, and retain solved capability cases as regression
  evidence. This skill additionally requires a supported success selector before
  treating best-of-k as deployed retry performance and separates reference-output
  acceptance from reachability with the allowed tools. The article's examples do
  not mandate dataset sizes, multiple judges, partial-credit machinery, new metric
  implementations, or a framework migration.
- [OpenAI: Working with evals](https://developers.openai.com/api/docs/guides/evals)
  and [eval run output items](https://developers.openai.com/api/reference/resources/evals/subresources/runs/subresources/output_items/methods/retrieve).
  An eval run processes dataset rows with specified model and prompt settings.
  Each output item contains a sample and grader results. This skill uses test
  case, trial, and eval run consistently across providers; one trial can contain
  multiple calls. A comparison groups baseline and candidate runs.
- [OpenAI: Evaluation best practices](https://developers.openai.com/api/docs/guides/evaluation-best-practices).
  Sizes and structures evaluation around its objective, data, and metrics.
  Neither this guide nor Anthropic's guide requires a light/full evaluation
  ladder. This skill chooses scope and trials per case for the actual decision.
- [Cross-validation guidance](https://scikit-learn.org/stable/modules/cross_validation.html).
  Primary documentation for group-aware and time-aware splitting. Applying this
  guidance to shared sessions, documents, task templates, and synthetic ancestors
  is this skill's design recommendation.
- [Generalization in Adaptive Data Analysis and Holdout Reuse](https://arxiv.org/abs/1506.02629).
  Repeated candidate selection can overfit a holdout through its scores alone.
  A split consulted during hillclimbing is validation data, even when transcripts
  stay hidden. Reserve an independent final test for a final performance claim.
- [Adding Error Bars to Evals](https://arxiv.org/abs/2411.00640).
  Distinguishes variation across cases from variation across repeated answers.
  Supports paired case-level comparisons instead of treating every repetition
  as a new independent example.
- [Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena](https://arxiv.org/abs/2306.05685).
  Primary research on position, verbosity, and self-enhancement biases. Its older
  model-specific results do not establish the error rates of a current judge.
- [Judge context guidance](https://hamel.dev/blog/posts/evals-faq/how-much-of-a-trace-should-i-give-an-llm-judge.html).
  Give each judge relevant evidence and validate context choices against human
  labels. Preserve full available traces for diagnosis without sending all content
  to every grader by default.
- [Efficient Inference for Noisy LLM-as-a-Judge Evaluation](https://arxiv.org/abs/2601.05420).
  Primary statistical research on imperfect judges and uncertainty from calibration
  and evaluation samples. It supports choosing an estimator for the actual design,
  not applying prevalence correction to every judge score.
- Mike Taylor, [How to build good evals without getting lost or in trouble](https://x.com/hammer_mt/status/2109264599899914733)
  (practitioner note). Frames an eval as saved work
  replayed under new models or prompts to report failures, confirm improvement,
  or qualify a cheaper model; collects expert judgments inside the expert's own
  tools; and treats a bad grade as a prompt to inspect the data because the
  human label is not the ceiling. This skill adopts those points and makes
  starting-state capture and external-tool fixtures explicit for task replay. It does
  not adopt its fixed 90% judge-agreement bar, its storage vendor and task
  format, or copying credentials into the sandbox.
- The [practitioner checklist on evals](https://x.com/divaagurlxw/status/2115418017891020888)
  informed guidance on grouping trace failures, diagnosing retrieval and tool
  use, simulating users, checking answer order, and measuring cost per success.
  Its release and monitoring examples inform decision criteria and sampling
  design. The skill leaves deployment and recurring execution to the owner.

## Limits retained from the research

Upstream advice is not uniform. Binary grading, fixed label counts, and a particular
split ratio are useful defaults in some settings. They are not universal rules.
The upstream validation bootstrap example holds the observed production pass rate
fixed; it does not include uncertainty from sampling those production observations.
Its general claim that improving sensitivity reduces uncertainty more than improving
specificity is not adopted here. Both depend on the sampling design and parameters.

No cited method makes incomplete ground truth exhaustive. Novel-claim adjudication,
measurement versioning, and explicit unknown states are requirements of this skill's
evidence contract. They prevent a benchmark artifact from being mistaken for a
change in the evaluated system.

## Framework evidence

- [Promptfoo configuration](https://www.promptfoo.dev/docs/configuration/reference/)
  and [exports](https://www.promptfoo.dev/docs/configuration/outputs/).
  Existing framework execution, storage, and case exports reduce custom scope.
  Current docs can differ from a pinned release. The offline feasibility check
  used 0.123.1; its findings and exact implementation links are in
  [framework constraints](frameworks.md). Its fictional measurements prove no
  live Codex behavior. The upstream zero-weight metric example, generic PASS
  badge, and timeout setting do not establish our evidence contract.
- [Promptfoo 0.123.1 evaluator](https://github.com/promptfoo/promptfoo/blob/0.123.1/src/evaluator.ts)
  and [telemetry](https://github.com/promptfoo/promptfoo/blob/0.123.1/src/telemetry.ts).
  Replay shortcuts, resource fields, cancellation, and telemetry require
  separate checks. Disabled CLI analytics is not network containment.
- [Phoenix experiments](https://arize-phoenix.readthedocs.io/projects/client/api/experiments.html),
  [Braintrust experiments](https://www.braintrust.dev/docs/evaluate/run-in-code),
  and [Langfuse experiments](https://langfuse.com/docs/evaluation/experiments/experiments-via-sdk).
  Credible alternatives when already used or required by repo needs. Their
  arbitrary tasks and graders still require a domain contract and runtime
  qualification. No platform migration or hosted-data disclosure is implied.
