require "test_helper"
require "yaml"
require "open3"
require "json"

class OpencodeBudgetTest < ActiveSupport::TestCase
  setup do
    workflow = YAML.safe_load_file(Rails.root.join(".github/workflows/opencode.yml"))
    @script = workflow.fetch("jobs").fetch("opencode").fetch("steps").find { |step| step["id"] == "budget" }.fetch("with").fetch("script")
  end

  test "counts previous attempts of current run and both comment events" do
    [ "issue_comment", "pull_request_review_comment" ].each do |event|
      assert_equal "limit_exhausted", budget(event:, attempt: 3, admitted: [ [ 10, 1 ], [ 10, 2 ], [ 11, 1 ] ])
      assert_equal "allowed", budget(event:, attempt: 3, admitted: [ [ 10, 1 ], [ 11, 1 ] ])
    end
  end

  test "fails closed when current run or prior attempt history is missing" do
    assert_match(/Текущая попытка/, budget(event: "issue_comment", attempt: 2, admitted: [], missing_current: true))
    assert_match(/История задания/, budget(event: "issue_comment", attempt: 2, admitted: [], missing_job: true))
  end

  test "reports exhausted budget and timeout with current SHA without invoking a model" do
    assert_includes report(marker: "Лимит исчерпан (budget-v1)"), "`limit_exhausted`"
    timeout = report(marker: "Истекло время агента (budget-v1)")
    assert_includes timeout, "`timeout`"
    assert_includes timeout, "`abc123`"
    assert_includes timeout, "actions/runs/10/attempts/2"
  end

  test "does not report a skipped job or a fork" do
    assert_equal "", report(marker: nil, skipped: true)
    assert_equal "", report(marker: "Агент завершил работу (budget-v1)", fork: true)
  end

  private

  def budget(event:, attempt:, admitted:, missing_current: false, missing_job: false)
    input = { event:, attempt:, admitted:, missing_current:, missing_job:, script: @script }.to_json
    harness = <<~JS
      const input = JSON.parse(require('fs').readFileSync(0, 'utf8'));
      process.env.GITHUB_RUN_ATTEMPT = String(input.attempt);
      const context = { repo: { owner: 'owner', repo: 'repo' }, actor: 'owner', runId: 10,
        runAttempt: input.attempt, payload: input.event === 'issue_comment' ?
          { issue: { number: 7, pull_request: {} } } : { pull_request: { number: 7 } } };
      const runs = [
        { id: 10, display_title: 'opencode-budget-v1-pr-7', run_attempt: input.attempt },
        { id: 11, display_title: 'opencode-budget-v1-pr-7', run_attempt: 1 },
        { id: 12, display_title: 'старый запуск', run_attempt: 1 }
      ].filter(run => !input.missing_current || run.id !== 10);
      const listRuns = Symbol('runs'), listJobs = Symbol('jobs');
      const github = { rest: { actions: { listWorkflowRuns: listRuns, listJobsForWorkflowRunAttempt: listJobs },
        repos: { getCollaboratorPermissionLevel: async () => ({ data: { permission: 'admin' } }) } },
        request: async () => ({ data: { permissions: { actions: 'read' } } }),
        paginate: async (method, args) => {
          if (method === listRuns) return runs;
          if (input.missing_job) return [];
          const allowed = input.admitted.some(([id, attempt]) => id === args.run_id && attempt === args.attempt_number);
          return [{ name: 'opencode', status: 'completed', steps: allowed ?
            [{ name: 'Попытка допущена (budget-v1)', conclusion: 'success' }] :
            [{ name: 'Проверить бюджет PR', conclusion: 'skipped' }] }];
        } };
      const core = { info: () => {} };
      const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
      new AsyncFunction('github', 'context', 'core', input.script)(github, context, core)
        .then(value => process.stdout.write(value)).catch(error => process.stdout.write(error.message));
    JS
    output, error, status = Open3.capture3("node", "-e", harness, stdin_data: input)
    assert status.success?, error
    output
  end

  def report(marker:, skipped: false, fork: false)
    workflow = YAML.safe_load_file(Rails.root.join(".github/workflows/opencode-report.yml"))
    script = workflow.fetch("jobs").fetch("report").fetch("steps").first.fetch("with").fetch("script")
    input = { marker:, skipped:, fork:, script: }.to_json
    harness = <<~JS
      const input = JSON.parse(require('fs').readFileSync(0, 'utf8'));
      const context = { repo: { owner: 'owner', repo: 'repo' }, payload: { repository: { id: 1 },
        workflow_run: { id: 10, run_attempt: 2, path: '.github/workflows/opencode.yml',
          display_title: 'opencode-budget-v1-pr-7', html_url: 'https://github.com/owner/repo/actions/runs/10' } } };
      const listJobs = Symbol('jobs'), listComments = Symbol('comments');
      const github = { rest: { actions: { listJobsForWorkflowRunAttempt: listJobs },
        pulls: { get: async () => ({ data: { head: { sha: 'abc123', repo: { id: input.fork ? 2 : 1 } }, base: { repo: { id: 1 } } } }) },
        issues: { listComments, createComment: async args => process.stdout.write(args.body) } },
        paginate: async method => method === listComments ? [] : [{ name: 'opencode',
          conclusion: input.skipped ? 'skipped' : 'success', steps: input.marker ? [{ name: input.marker, conclusion: 'success' }] : [] }] };
      const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
      new AsyncFunction('github', 'context', 'core', input.script)(github, context, { warning: () => {} })
        .catch(error => { console.error(error); process.exitCode = 1; });
    JS
    output, error, status = Open3.capture3("node", "-e", harness, stdin_data: input)
    assert status.success?, error
    output
  end
end
