# Multiple parents: implementation handoff

This file is the starting point for a Claude Code session that implements multiple parents per project.
The design is in [`MULTIPLE_PARENTS_PLAN.md`](MULTIPLE_PARENTS_PLAN.md), referred to below as "the plan". Section
numbers such as §5.1 refer to the plan.

- **Branch:** `multiple-parents`. Develop, commit and push only there.
- **Base at handoff:** `a1cc5ce`, which equals `origin/main` at that time.
- **State at handoff:** design only. No implementation code, no migration, and no ADR exist yet.

---

## 1. Read first

1. This file, completely.
2. The plan, §0 to §4 completely. Then read the sections that the current work package references.
3. `AGENTS.md` (`CLAUDE.md` is a symlink to it), `DEVELOPING.md`, `docs/PERSISTENCE.md`,
   `docs/PORTFOLIO_ACCESS_CONTROL.md` and `docs/DATABASE_MIGRATIONS.md`.

**How binding is the plan?**
- Decisions D0 to D14 (plan §3) are the agreed direction. They came out of several review rounds with the user.
- They are **not** yet an accepted ADR.
- If implementation shows that a decision does not work, stop and ask the user. Do not silently deviate.
- Record every deviation in §7 of this file and in the plan's change log (§19.2).

---

## 2. Environment (Claude Code on the web)

`.claude/hooks/session-start.sh` runs at session start. It is registered in `.claude/settings.json` and only
runs in cloud sessions. It prepares the following:

| Need | Provided by the hook | Why |
|:--|:--|:--|
| JDK 25 | `openjdk-25-jdk-headless` via apt. `JAVA_HOME` and `PATH` are exported to the session. | The Maven enforcer requires `[25,)`, and the image ships JDK 21 with `JAVA_HOME` pointing to it. |
| Docker daemon | `dockerd` started in the background | Tests use Testcontainers (`postgres:14-alpine`). |
| Image pulls | `TESTCONTAINERS_HUB_IMAGE_NAME_PREFIX=mirror.gcr.io/` and `TESTCONTAINERS_RYUK_DISABLED=true`. The test database image is pre-pulled. | Anonymous Docker Hub pulls get HTTP 429 behind the proxy. |
| Migration linter | `squawk-cli==2.63.0` from PyPI, wrapped in the local image `dt-local/squawk:2.63.0` | The proxy blocks ghcr.io blob downloads, so the Makefile's Squawk image cannot be pulled. |
| `BASE_REF` | `origin/main`, fetched shallowly | `make lint-migrations` diffs against it. |
| Warm Maven | `make install AGENT=1`, with tests skipped | Makes the first build and test much faster. |

**Verify at session start:**

```bash
java -version                                  # expect 25
echo "$JAVA_HOME"                              # expect /usr/lib/jvm/java-25-openjdk-amd64
docker info --format '{{.ServerVersion}}'      # expect a version, not an error
echo "$TESTCONTAINERS_HUB_IMAGE_NAME_PREFIX"   # expect mirror.gcr.io/
git rev-parse --verify origin/main
```

If something is missing, run the hook manually:
`CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR=$PWD .claude/hooks/session-start.sh`.
Then `export` the variables it would have written. Its logs are `/tmp/dockerd.log` and
`/tmp/session-start-maven.log`.

**Commands.** These are the `AGENTS.md` targets, with the overrides needed in this environment:

| Purpose | Command |
|:--|:--|
| Build | `make build AGENT=1` |
| One test class or method | `make test-single MODULE=apiserver TEST=ProjectHierarchyMaintenanceTest AGENT=1` |
| Several tests | `make test-single MODULE=apiserver TEST="ProjectDaoTest,ProjectResourceTest" AGENT=1` |
| Format Java (after any `.java` or `pom.xml` change) | `make format-java AGENT=1` |
| Lint migrations (after any migration SQL change) | `make lint-migrations SQUAWK_IMAGE=dt-local/squawk:2.63.0 AGENT=1` |
| Lint OpenAPI (after any `api/src/main/openapi/**` change) | `make lint-openapi AGENT=1`. If the Spectral pull fails with 429, retry later, or pass `SPECTRAL_IMAGE=mirror.gcr.io/stoplight/spectral:6.16.3`. |
| Migration module tests | `make test-single MODULE=migration TEST=<TestClass> AGENT=1` |

**Notes:**
- With `AGENT=1`, Maven runs quietly. A zero exit code is success, even with no output.
- Error Prone runs during compilation, so its findings fail the build. Fix them; don't suppress them.
- `lint-proto` needs `buf`, which is not installed. The plan changes no `.proto` files.
- **Testcontainers reuse gotcha:** `PostgresTestContainer` skips migrations when a container is reused. After
  adding or changing a migration, remove old test containers:
  `docker rm -f $(docker ps -aq --filter label=org.dependencytrack.test-database)`.

---

## 3. Ground rules

Most of these come from `AGENTS.md`, and they are not optional.

- **Tooling:**
  - Use `make` targets with `AGENT=1`.
  - Invoke Maven directly only if no target exists, and only from the repository root.
- **Architecture:**
  - Persistence: new code uses JDBI and raw SQL. JDO changes are limited to the `Project.parents` mapping (D11).
    Before mixing JDO and JDBI, read `docs/PERSISTENCE.md`.
  - Nullability: every new package needs a `package-info.java` with `@NullMarked`.
  - Long-running work must be interruptible. Check at batch boundaries, and never swallow
    `InterruptedException`.
- **API:**
  - The v1 contract must not break (ADR 036). New endpoints go only to spec-first v2 (ADR 007), with API
    models decoupled from persistence.
  - Portfolio access control: any PAC-sensitive change ships with tests for the accessible case, the 403
    case, and the bypass permission. Call `enablePortfolioAccessControl()` in the test setup.
- **Migrations:**
  - Create them with `make new-migration NAME="..."`.
  - Versioned files become immutable once merged to `main`. Until then they may be edited on this branch.
- **Commits:**
  - Always `git commit -s`. The subject is capitalized, imperative, with no prefix and no trailing period.
    The body explains what and why.
  - **No AI attribution:** no `Co-authored-by` naming an assistant, no session links, no "generated with".
- **Git:**
  - Push with `git push -u origin multiple-parents` after every completed work package. Containers are
    ephemeral, and unpushed work is lost.
  - **Never create issues or PRs** (see `AGENTS.md`).
- **Scope:** do not change behaviour outside the plan. List unrelated findings in handoff §7 instead.

---

## 4. Work packages

Do them in order. Each one should end green and pushed. Update the progress log (handoff §6) as you go.

### WP0: Baseline

- Run the tests that later packages will touch, **before changing anything**:
  - `ProjectHierarchyMaintenanceTest`, `ProjectDaoTest`, `ProjectTest`
  - `ProjectResourceTest` (large), `MetricsResourceTest`, `BomResourceTest`
  - `ProjectIsAccessibleByMethodTest`, `ApiRequestStatementCustomizerTest`
  - `CelPolicyEngineTest`, `NotificationRouterTest`, `ProcessScheduledNotificationRuleActivityTest`
- Record pre-existing failures in handoff §7, so they are not mistaken for regressions later.
- **Done when:** the results are recorded.

### WP1: ADR 043 draft (plan §14)

- Create `docs/adr/043-multiple-project-parents.md` from `docs/adr/000-template.md`, with status **Proposed**.
  Follow the style rules in `docs/adr/README.md`: B1 English, short sentences, no em-dashes or semicolons,
  reference-style links, Mermaid diagrams.
- Content comes from plan §14 and §2 to §3.
- **Ask the user for the author's GitHub handle.** Do not invent one.
- **Done when:** the file exists and is committed. Posting it upstream is the user's job (D0).

### WP2: De-risking spikes

These are throwaway tests; delete them or fold them into real tests later. They verify the assumptions that
the plan marks as *inferred*:

1. **Trigger ordering during `DELETE FROM "PROJECT"`** (§5.2). The edge-delete trigger must see deleted
   parents as gone. The `PROJECT` statement trigger runs afterwards.
2. **DataNucleus self-referential M:N** (§8.1). `parents` uses `@Join`, and `children` uses
   `mappedBy = "parents"`. Check enhancement, fetch groups `ALL` and `PARENTS`, detach, and the order of
   join-row inserts relative to the project insert.
3. **Advisory lock**. Two concurrent edge inserts that would form a cycle: exactly one fails. Try the deadlock
   scenario from §5.3 and confirm that `ProjectDao.lockHierarchy()`-first avoids it.
4. **Mirror guard** (§7.2). The `set_config('dtrack.project_parent_sync', …)` guard prevents echo loops.
   A column write and an edge write each end in a consistent state.

- **Done when:** the findings are recorded in handoff §7. If a finding contradicts the plan, **stop and ask the user**.

### WP3: Schema and triggers, release N expand (plan §4 to §7)

- **Migrations:**
  - M1 `add_project_parents`: table, backfill, trigger replacement, closure rebuild, refresh function, edge
    triggers, mirror triggers, and dropping `PROJECT_PROJECT_FK`.
  - M3 `add_project_hierarchy_child_idx`, plus its `.sql.conf`.
  - Update `R__clone_project.sql`.
- **Tests:**
  - `AddProjectParentsMigrationTest`.
  - Extend `ProjectHierarchyMaintenanceTest` with DAG cases. Insert edges into `PROJECT_PARENTS` with raw
    SQL, because the Java layer is not switched yet.
  - A property-based test against a recursive-CTE ground truth.
  - Concurrency, delete/orphan-cascade, deep-chain (50 levels) and mirror tests. See plan §15 for the lists.
- **Done when:** the tests pass, `make lint-migrations SQUAWK_IMAGE=dt-local/squawk:2.63.0 AGENT=1` is clean,
  and the existing tests from WP0 are unchanged.

### WP4: Persistence switch, API still single-parent (plan §8)

- JDO `parents`/`children` mapping. Remove the `parent` field mapping. Keep `getParent()` as a derived,
  deprecated getter.
- `ProjectQueryManager` create and update:
  - Diff parent sets, run batched validations, and take `lockHierarchy()` first.
  - **Resolve parents before setting any other field.** See commit `8f399b6`: a JDO query flushes dirty
    state and can violate `PROJECT_COLLECTION_CLASSIFIER_check`.
- `ProjectDao` fragments:
  - `hasChildren`, `onlyRoot`, `parentUuidFilter`.
  - The ACL-filtered `parentsJson`, which also fixes the list-endpoint parent leak.
  - The `deleteProjects` rework, and new DAO methods.
- `MetricsDao` and `COLLECTION_METRICS_SUBQUERY`: `UNION` plus distinct leaves (D14).
- Migrate about 67 `project.setParent(...)` test call sites to `setParents(...)` or `addParent(...)`. Update
  `ProjectTest.shouldCascadeDeleteOfParent`.
- The API still accepts exactly one parent.
- **Done when:** all WP0 tests pass, apart from the intentional updates listed above. `make format-java AGENT=1`
  has been run.

### WP5: Multiple parents behind the flag, in v1 (plan §9, §11; D5, D9, D12, D13, D14)

- Add `ConfigPropertyConstants.PROJECT_MULTIPLE_PARENTS_ENABLED`, modelled on `ACCESS_MANAGEMENT_ACL_ENABLED`,
  with default `false`.
- Validation rules:
  - the cap of 100;
  - the extra `ACCESS_MANAGEMENT` or bypass requirement when PAC is on and the project ends up with more
    than one parent;
  - preserving parents the caller cannot access.
- v1 `parents` in single and list responses, deprecated `parent`, and the full §9.2 request matrix.
- Tests: ACL, flag and permission, round-trip (D13), collection diamond, policy and notification. See plan §15.
- **Done when:** the tests pass, and with the flag **off** the existing behaviour is unchanged.

### WP6: API v2 (plan §10, §8.5)

- Add the OpenAPI files under `api/src/main/openapi/resources/projects/` and `resources/vulns/`, and register
  them in `openapi.yaml`. Schema basenames must be globally unique; `lint-openapi` checks this.
- Endpoints:
  - `GET /projects/{uuid}/parents` and `GET /projects/{uuid}/children`;
  - `PUT` and `DELETE /projects/{uuid}/parents/{parent_uuid}`;
  - the atomic `PATCH /projects/{uuid}/children`;
  - `GET /vulns/{source}/{vuln_id}/affected-projects` with `relation=direct|ancestor`.
- Implement them in `resources/v2/` on JDBI. The affected-ancestors query goes in `VulnerabilityDao`, reusing
  the v1 "affected" predicate.
- **Done when:** the v2 tests pass (plan §15) and `make lint-openapi AGENT=1` is clean.

### WP7: End-to-end scenario and in-repo docs

- Add the end-to-end scenario from plan §15 as an apiserver resource-level test: two customers share a
  product, a CVE, a deployment swap.
- Update `docs/PORTFOLIO_ACCESS_CONTROL.md` (plan §14).
- Add the "Follow-up" section to ADR 005.
- Add the modelling guidance (plan §12) as an appendix to ADR 043.
- **Done when:** the tests pass and the docs are committed.

### Not in scope for this branch

- **WP8 (release N+1 contract):** M2 drops the mirror triggers and the column. Only do this when the user
  says release N has shipped.
- The frontend (`DependencyTrack/frontend`), the public docs (`DependencyTrack/docs`), posting the upstream
  discussion, and multiple parents on BOM upload (D10).

---

## 5. Where the plan is inferred, not verified

Treat these as hypotheses. WP2 covers the first four.

- Trigger ordering between the RI cascade and statement-level triggers (§5.2).
- DataNucleus behaviour for a self-referential M:N collection, and its flush order (§8.1).
- The deadlock mitigation around the advisory lock (§5.3).
- The mirror-trigger guard, and trigger name ordering on `PROJECT` INSERT (§5.2, §7.2).
- `@DefineApiProjectAclCondition` is not `@Repeatable`. The parent-alias ACL condition needs one of the two
  options in §8.3.
- Orphan-cascade recursion versus `max_stack_depth` (the deep-chain test).
- The BOM auto-create 500 on an inactive parent (plan §16 item 2) is unconfirmed and optional.

---

## 6. Progress log

The implementing session keeps this table current, and pushes it together with each work package.

| WP | Status | Commits | Notes |
|:--|:--|:--|:--|
| WP0 Baseline | Not started | | |
| WP1 ADR 043 draft | Not started | | Needs the author handle from the user |
| WP2 Spikes | Not started | | |
| WP3 Schema and triggers | Not started | | |
| WP4 Persistence switch | Not started | | |
| WP5 v1 behind the flag | Not started | | |
| WP6 API v2 | Not started | | |
| WP7 End-to-end and docs | Not started | | |

---

## 7. Findings, deviations and open questions

**Open questions for the user.** Ask; don't guess.

- The GitHub handle for the ADR's author field (WP1).
- The version string for `@Deprecated(since = …)` and the upgrade notes. The branch is `5.2.0-SNAPSHOT`, so
  release N is presumably 5.2.0. Confirm.
- Storage of the feature flag: a DB config property, which is the plan's default, or an application property
  (plan §18).

**Findings and deviations:** none yet.

---

## 8. Kickoff prompt for the next session

> Work on branch `multiple-parents`. Read `MULTIPLE_PARENTS_HANDOFF.md` completely, then
> `MULTIPLE_PARENTS_PLAN.md` §0 to §4. Verify the environment as described in handoff §2. Then continue with
> the first work package in the progress log (handoff §6) that is not done. Follow the ground rules in
> handoff §3. Commit with sign-off after each logical step. Push after each work package, and update the
> progress log. Ask me before deviating from a plan decision, and for the open questions in handoff §7.
