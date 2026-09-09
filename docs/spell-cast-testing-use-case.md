# Spell casting in bounded test sequences

## Use case

A script developer wants to compare a spell against several creatures or test
equipment and combat edge cases. Each trial has a particular target, a limited
time/resource allowance, and an operator who can stop the trial. The developer
wants to use `Spell[number].cast(target)` rather than duplicate Lich's spell
preparation, targeting, resource checks, and result handling.

Ordinary casting helpers sensibly try to finish an operation. A supervised test
has an additional requirement: if its target changes, its allowance expires,
or the operator withdraws permission, an already-running helper must not issue
another command under the old authorization. Checking only before entering
`cast` is insufficient because that invocation can wait and send multiple
commands before returning.

This is an execution-lifetime problem, not a proposal to remove normal retry
behavior or replace the spell system.

## What the current implementation actually does

The relevant implementation is [`Spell#cast`](../lib/common/spell.rb), including
the `force_cast`, `force_channel`, `force_evoke`, and `force_incant` wrappers.
Depending on its arguments and state, one invocation can:

- Wait for the shared casting lock, roundtime, or cast roundtime.
- Release a different prepared spell, prepare the requested spell, and change
  stance before sending `cast`/`channel`/`evoke`; alternatively use `incant`.
- Repeat preparation when the preparation loop receives no recognized terminal
  result, including an unanswered preparation. Specific preparation failures
  already return their result instead of retrying.
- Reissue the casting command after the inability-to-move response and its
  recovery wait, or after the special `incant` preparation-time response.
- Fall back from unsupported evoke/channel to cast.
- Repeat the outer loop for the explicit circle-10 spell-hindrance case.
- Restore stance, or run a spell-specific `cast_proc` instead of this generic
  sequence.

It is **not** accurate to describe this as retrying every spell on every
hindrance or roundtime response. The branches above are specific to the current
code. The proposed change preserves them when no guard is installed.

For example, if an unanswered `prepare` causes another preparation attempt,
the outer test harness has not yet regained control to enforce its deadline.
Likewise, permission can be withdrawn after preparation but before the target
command. Killing the entire script is not equivalent to orderly interruption
through the helper's cleanup path.

## Proposed API: reuse the script execution guard

This integration depends on the independently reviewed script-execution guard
API. It should be rebased and submitted only after that core API lands; the
Spell change itself remains limited to cooperative wait checkpoints and its
focused regression coverage.

There is no new `Spell#cast` argument and no `cast_once` method in this change.
The opt-in interface is the general
[`Script#with_execution_guard`](script-execution-guard.md):

```ruby
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10.0
policy = lambda do |_wire_command|
  Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
end

begin
  Script.current.with_execution_guard(policy) do
    result = Spell[spell_number].cast(target_id)
    # Record the returned result alongside the trial's observations.
  end
rescue Lich::Common::ScriptExecutionGuard::Interrupted => error
  echo "Trial interrupted: #{error.reason}"
end
```

This illustrative policy only supplies a deadline. A real test supervisor also
checks its locally recorded cancellation, target/room identity, resource limits,
and authorized commands. The policy must return literal `true` to continue and
must not issue game commands. It receives `nil` at a checkpoint or the immutable
wire command immediately before a guarded game write. The wire command may
include the frontend command prefix; it is not necessarily a bare `cast` string.

The block can receive a cancellation handle for an operator's stop signal.
Cancellation latches: swallowing the interruption inside a spell-specific
`cast_proc` does not authorize subsequent writes or successful scope completion.
The cast lock and downstream subscription flags are released/restored through
`Spell#cast`'s existing `ensure` path. This does not promise in-game stance,
equipment, or prepared-spell restoration after interruption; any subsequent
recovery requires its own valid authorization.

The guard is cooperative, not a sandbox or a preemptive Ruby timeout. It covers
the native write/read/wait checkpoints documented in the guard contract.
Arbitrary Ruby loops, direct socket access, and uninstrumented blocking calls
remain outside that coverage. Separately started child scripts are not implicitly
covered by a parent's scoped guard.

## Preparation, cast attempts, and wire sends are different

A test must name the unit it is limiting. An invocation of `cast`, a permitted
socket-write attempt, a server-accepted cast, and a damage event are not
interchangeable:

- `prepare 101` followed by `cast #123` already involves two sends, before any
  release or stance commands. Limiting a whole helper to one send may prevent it
  from ever casting.
- `incant` can combine work that the explicit prepare/cast path separates, and
  its preparation-time branch can issue it again.
- Permission to write does not prove delivery or server execution. A missing
  response leaves an ambiguous result, not evidence that the attempt never
  happened.
- One accepted spell can produce multiple observed combat effects. Damage-event
  counts are not cast counts either.

The guard therefore provides bounded execution, **not universal exactly-once
spell semantics**. A policy can limit wire attempts or reject later sends after
an observed outcome. A test needing exactly one server-accepted cast must define
and verify the spell-specific observation contract and report ambiguous outcomes
as inconclusive; it cannot obtain that guarantee from a generic send counter.

## Verification already present

[`spell_execution_guard_spec.rb`](../spec/lib/common/spell_execution_guard_spec.rb)
executes production `Spell#cast` and the native guard, with a deterministic
`dothistimeout` command/result boundary. It checks:

- Rejection between preparation and casting, including a non-boolean denial.
- Interruption before a preparation timeout retry, cleanup, and a subsequent
  unaffected unguarded cast.
- The forced cast/channel/evoke wrappers and the incant preparation-time retry.
- Normal unguarded results and an allowed guarded channel sequence.
- Latched cancellation when a spell-specific `cast_proc` catches the exception.

[`game_execution_guard_spec.rb`](../spec/lib/game_execution_guard_spec.rb)
separately checks the production socket-write seam with a fake socket: rejection
before the send/echo, immutable exact commands, one check for `puts` delegation
to `_puts`, and separate checks for repeated sends. The Script and native-wait
guard suites cover scope cleanup, cancellation, and cooperative checkpoints.
These are offline regression tests, not a claim of live spell acceptance.

## Remaining acceptance work

Before claiming a particular live combat trial is supported:

1. Add deterministic response fixtures for the retry branches that trial uses,
   especially circle-10 hindrance or spell-specific `cast_proc` behavior; do not
   assume the existing focused suite exhausts every spell branch.
2. With player authorization, verify a normal cast and an interruption at a
   known checkpoint, recording attempted sends and observed game results
   separately. Do not provoke dangerous failures merely to obtain a fixture.
3. Confirm casting lock/subscription cleanup and a subsequent ordinary cast.
4. Verify the surrounding supervisor's safe-start/safe-return and recovery
   behavior independently. A guard does not itself move a character to safety.

## Relationship to the future spell refactor

The guard is a Lich script-execution facility with no LAB dependency. Any script
can opt in; ordinary callers keep their existing API and behavior. LAB or
Bigshot can supply policies without becoming dependencies of `Spell`.

This proposal makes no choice between `effect-list.xml`, JSON/YAML, or direct
Ruby spell definitions. Those are separate representation and maintenance
decisions. A future spell implementation should preserve the general guarded
execution contract and its regression tests rather than retain today's internal
loops merely for compatibility with a test harness.
