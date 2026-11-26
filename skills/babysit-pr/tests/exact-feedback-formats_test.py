"""Frozen public bot bodies through production feedback and signoff entrypoints."""
import json
import os
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(os.environ.get('EXACT_FORMATS_TEST_SOURCE', pathlib.Path(__file__).resolve().parents[2]))
FIX = pathlib.Path(__file__).resolve().parents[2] / 'babysit-pr/tests/fixtures/exact-formats'
SH = r'''
set -euo pipefail
. babysit-pr/lib/jq-defs.sh
. babysit-pr/lib/feedback-gate.sh
. babysit-pr/lib/feedback-counts.sh
ME=tester
issue_comments_json() { cat "$1"; }
pull_reviews_json() { printf '%s' "$REVIEWS"; }
pull_comments_json() { printf '[]'; }
review_threads_json() { printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'; }
sget() { printf '%s' "$FIXTURE_HEAD"; }
printf '[%s,%s,%s]' "$(unreplied_issue_comment_count "$DATA")" "$(new_issue_feedback_count "$DATA" 0)" "$(untriaged_review_body_count "$DATA")"
'''


def fixture_body(name):
    return json.loads((FIX / (name + '.json')).read_text())['body']


def run(body, author='reviewer[bot]', review=False, head=None):
    import os
    import tempfile
    node = dict(id=10, user=dict(login=author), body=body, created_at='2098-01-01T00:00:00Z',
                submitted_at='2098-01-01T00:00:00Z', state='COMMENTED')
    with tempfile.NamedTemporaryFile(mode='w') as data:
        json.dump([] if review else [node], data)
        data.flush()
        env = dict(os.environ, DATA=data.name, REVIEWS=json.dumps([node] if review else []),
                   FIXTURE_HEAD=head or 'f81f8253e9862b90968f51c5da4238234d411af5')
        return json.loads(subprocess.check_output(['bash', '-c', SH], cwd=ROOT, env=env))


class ExactFormats(unittest.TestCase):
    def test_marked_container(self):
        body = fixture_body('codex-container')
        for text, expected in [(body, 0), (body.replace('<!-- codex-review-receipt:v1 -->', ''), 0),
                               (body.replace(':v1', ':v2'), 1), (body + '\nRestore guard.', 1),
                               (body.replace('-->', '->', 1), 1),
                               (body.replace('<!-- codex-', '<!--  codex-', 1), 1),
                               (body.replace('receipt:v1', 'receipt:\nv1', 1), 1),
                               ('<!-- codex-review-receipt:v1 -->\n' + body, 1)]:
            with self.subTest(text=text[:60], expected=expected):
                self.assertEqual(run(text, 'chatgpt-codex-connector[bot]', True)[2], expected)
        self.assertEqual(run(body, 'other[bot]', True)[2], 1)

    def test_paired_inventory(self):
        body = fixture_body('codex-container')
        import tempfile
        script = r'''set -euo pipefail
. address-feedback/scripts/lib/codex-threads/jq-defs.sh
. address-feedback/scripts/lib/codex-threads/sections.sh
CODEX_LOGIN='chatgpt-codex-connector[bot]'
HEAD_SHA=ffffffffffffffffffffffffffffffffffffffff
print_review_bodies
'''
        with tempfile.TemporaryDirectory() as work:
            for text, listed in [(body, False), (body.replace(':v1', ':v2'), True),
                                 (body + '\nRestore guard.', True),
                                 (body.replace('-->', '->', 1), True),
                                 (body.replace('<!-- codex-', '<!--  codex-', 1), True),
                                 (body.replace('receipt:v1', 'receipt:\nv1', 1), True),
                                 (body.replace('<!-- codex-review-receipt:v1 -->', ''), False)]:
                pathlib.Path(work, 'reviews.json').write_text(json.dumps([dict(
                    id=10, user=dict(login='chatgpt-codex-connector[bot]'),
                    commit_id='a' * 40, state='COMMENTED', body=text)]))
                output = subprocess.check_output(['bash', '-c', script], cwd=ROOT,
                                                 env=dict(os.environ, WORK_DIR=work), text=True)
                self.assertEqual('top-level-response review 10' in output, listed)
                if listed:
                    self.assertIn('superseded head', output)

    def test_claude_review_pass(self):
        # A real claude-code-action summary (the login replaced). The clean
        # shape keeps its header, rule and checklist and ends with the result
        # line: the real body predates the prompt that asks for that shape.
        real = fixture_body('claude-review-summary')
        lines = real.split('\n')
        kept = lines[:3] + [line for line in lines if line.startswith('- [')]
        clean = '\n'.join(kept) + '\n\nReview result: LGTM, no findings\n'
        last = 'Review result: LGTM, no findings'
        bot = 'github-actions[bot]'
        for text, author, expected in [
                (clean, bot, 0),
                (clean.replace('@maintainer', '@dev_acme', 1), bot, 0),
                (real, bot, 1),
                (real + '\n\n' + last + '\n', bot, 1),
                (clean, 'claude[bot]', 1),
                (clean.replace(last, '1. Restore the deleted guard.\n' + last), bot, 1),
                (clean.replace(last, '### Verdict: needs-discussion\n' + last), bot, 1),
                (clean.replace('---\n', '---\n### Review complete\n', 1), bot, 1),
                (clean.replace('- [x] Post findings', '- [x] Post findings [P2]'), bot, 1),
                (clean + 'Restore the deleted guard.\n', bot, 1),
                (clean.replace(last, last + ' yet'), bot, 1),
                (clean.replace('**Claude finished', '**Claude encountered an error', 1), bot, 1),
                (clean.replace('[View job](https://github.com/', '[View job](https://example.com/', 1), bot, 1),
                (last, bot, 1)]:
            with self.subTest(text=text[-60:], author=author, expected=expected):
                self.assertEqual(run(text, author)[:2], [expected, expected])


if __name__ == '__main__':
    unittest.main()
