import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Private sentinel used by [ToolsContainer]'s constructor to distinguish
/// "the `hostUserFlag` parameter wasn't passed at all" (auto-detect) from
/// "it was explicitly passed as `null`" (force no `--user` override) — see
/// the constructor's own doc comment on why a plain `String?` default of
/// `null` can't make that distinction.
const Object _hostUserFlagNotProvided = Object();

/// Container-orchestration plumbing for Phase 2 of issue #76 (Design A —
/// Docker-containerized tool runtime).
///
/// [ToolsContainer] starts a single long-lived container from the
/// `media-pipeline-tools` image (Phase 1, `docker/tools/Dockerfile`, PR #80),
/// binds one host directory into it, execs tool invocations into that running
/// container (`docker exec`, avoiding a fresh `docker run` per call), and
/// tears the container down cleanly when the session ends.
///
/// ## What this PR does NOT do
///
/// This is infrastructure only. No consumer in this codebase
/// (`stitch_metadata.dart`, `dedupe_live_photos.dart`,
/// `clean_takeout_duplicates.dart`, `drive_detection.dart`,
/// `delete_duplicates.dart`) is wired to use this class yet — each of those
/// still shells out to the host binary directly via its own overridable
/// `Process.run`-based seam (`exiftoolRunner`, `$FFPROBE_BIN`-style
/// overrides, `sha256sum`, etc.). Wiring happens in later Phase 2 PRs, one
/// consumer at a time, matching how Phase 0b ported one script at a time.
/// See this issue's roadmap for the full phase breakdown.
///
/// ## Keep-alive mechanism
///
/// `docker/tools/Dockerfile`'s own `CMD` is `["bash"]` with no `ENTRYPOINT`
/// override — a bare `docker run` (no `-d`, no TTY) would start `bash`,
/// immediately hit EOF on stdin, and exit. Rather than modify the Dockerfile
/// (out of scope for this PR; Phase 1 already shipped and is reused
/// unmodified), [start] overrides the container's command at the `docker
/// run` invocation itself: `docker run -d ... $image sleep infinity`. This
/// is a standard, supported Docker idiom for exactly this "keep a container
/// alive as an exec target" use case and needs no image change.
///
/// ## Cleanup / leaked-container avoidance
///
/// [start] always passes `--rm` to `docker run`, so the container is
/// scheduled for automatic removal by the Docker daemon the moment it stops.
/// [stop]/[dispose] additionally issue an explicit `docker rm -f` after
/// `docker stop`, so removal is synchronous from the caller's point of view
/// too (see [stop]'s own doc comment for why `--rm` alone wasn't enough on
/// its own during this PR's testing). Every started container is also
/// labelled
/// `${kToolsContainerSessionLabel}=<session-id>` (see [start]) so orphaned
/// containers from an abnormal Dart-process termination (e.g. `SIGKILL`,
/// which no userspace process — Dart included — can intercept) can still be
/// found and reaped with `docker ps -a --filter label=$kToolsContainerSessionLabel`;
/// that residual risk (an uncatchable kill signal leaking a container) is
/// inherent to any "detached long-lived subprocess" design and is not fully
/// closable from inside the Dart process itself. [ToolsContainer.withSession]
/// is the recommended entry point for callers: it wraps [start]/[stop] in a
/// `try`/`finally` so a normal exception (including one thrown by the
/// caller's own callback) can never skip cleanup — only an uncatchable
/// process kill can.
///
/// ## Path translation
///
/// [hostToContainerPath] / [containerToHostPath] translate between a host
/// absolute path under [hostMountRoot] and its mounted location under
/// [containerMountPath] (`/data` by default), a simple, pure prefix-rewrite
/// — see their doc comments for the fail-loud-on-escape contract this repo's
/// Safety Rules require (a path outside the mounted root must never be
/// silently mistranslated).
///
/// Windows-style host paths (`C:\...`) and the different `docker run -v`
/// bind-mount syntax Docker Desktop on Windows/macOS needs are explicitly
/// out of scope for this PR — that's Phase 4/5 of issue #76 (macOS/Windows
/// end-to-end verification), which this repo's own real-machine test
/// precedent (see `test/drive_detection_test.dart`'s `Platform.isLinux`
/// skip) already treats as separate, platform-gated work. This PR's own
/// Docker-backed tests are Linux-gated the same way (see
/// `test/tools_container_test.dart`).
///
/// ## Host UID/GID mapping (#76 Phase 3)
///
/// `docker/tools/Dockerfile` bakes in a fixed non-root user (`tools`, uid
/// 10000) as a safe default for the image's own standalone verification.
/// Left alone, that means every file the container creates on the
/// bind-mounted host directory ends up owned by uid 10000 on the host — not
/// the real host user — and, symmetrically, a host-created file the
/// container's fixed uid lacks permission on fails to read/write from
/// inside the container. PRs #94/#95/#96 (the first three consumer
/// migrations) each independently hit this permission-denied failure and
/// worked around it with a test-only `chmod 0777`/`0666` on their fixture
/// directories, flagging it as an open Phase 3 gap each time.
///
/// [start] closes that gap by passing `--user <host-uid>:<host-gid>` to
/// `docker run`, overriding the image's baked-in `tools` user for this one
/// container instance — a per-run override, the standard Docker-on-Linux
/// idiom for exactly this bind-mount-ownership problem; the image's own
/// `USER tools` default (`docker/tools/Dockerfile`) is untouched, so
/// standalone/debugging use of the image (`docker run -it
/// media-pipeline-tools:local bash`, no `--user`) behaves exactly as
/// before. [detectHostUserFlag] resolves the current process's real
/// UID/GID via `id -u`/`id -g` (Linux/macOS only — see its own doc comment
/// for why Windows and detection-failure both intentionally fall back to
/// `null`, i.e. no `--user` override, rather than throwing). All four
/// bundled tools (`exiftool`, `ffmpeg`/`ffprobe`, `rclone`, `czkawka_cli`)
/// plus `sha256sum` were verified running correctly as an arbitrary host
/// UID with no corresponding `/etc/passwd` entry inside the container —
/// only `whoami`/username-lookup style operations fail in that situation
/// (`cannot find name for user ID <uid>`), and none of these tools rely on
/// one.
class ToolsContainer {
  ToolsContainer({
    required this.hostMountRoot,
    this.containerMountPath = '/data',
    this.image = kDefaultToolsImage,
    this.dockerBin = 'docker',
    DockerProcessRunner? runner,
    // `Object?` with a private sentinel default (not `String?` defaulting
    // to `null`) so this constructor can tell "caller didn't pass
    // hostUserFlag at all -> auto-detect" apart from "caller explicitly
    // passed hostUserFlag: null -> force no --user override" (e.g. a test
    // simulating Windows). A plain `String? hostUserFlag` parameter can't
    // make that distinction — both cases would otherwise look identical
    // (`null`) inside the constructor body.
    Object? hostUserFlag = _hostUserFlagNotProvided,
  }) : runner = runner ?? _defaultRunner(dockerBin),
       hostUserFlag = identical(hostUserFlag, _hostUserFlagNotProvided)
           ? detectHostUserFlag()
           : hostUserFlag as String?,
       // Normalized (not just trailing-slash-stripped) up front, so a root
       // itself constructed with `.`/`..` segments doesn't skew every later
       // boundary check — see [_normalizeAbsolutePath]'s doc comment. This
       // also performs (and throws on failure of) the "must be absolute"
       // validation, so no separate check is needed in the body below.
       _normalizedHostRoot = _normalizeAbsolutePath(
         hostMountRoot,
         argumentName: 'hostMountRoot',
       ),
       _normalizedContainerRoot = _normalizeAbsolutePath(
         containerMountPath,
         argumentName: 'containerMountPath',
       );

  /// The host directory bind-mounted into the container at
  /// [containerMountPath]. Typically the target media drive root.
  final String hostMountRoot;

  /// The fixed path inside the container that [hostMountRoot] is mounted at.
  final String containerMountPath;

  /// The `media-pipeline-tools` image tag to run. Defaults to
  /// [kDefaultToolsImage]; overridable so tests/CI can point at a locally
  /// built or differently-tagged image (matching this repo's
  /// overridable-binary-name convention used throughout
  /// `dedupe_live_photos.dart`/`stitch_metadata.dart`).
  final String image;

  /// The `docker` executable name/path. Overridable for tests, mirroring
  /// every other external-tool seam in this codebase.
  final String dockerBin;

  /// The seam all `docker` invocations go through. The default
  /// ([_defaultRunner]) shells out to the real `docker` CLI via
  /// `Process.run`; tests inject a fake to exercise [start]/[exec]/[stop]'s
  /// argument-building and error-handling logic without needing a real
  /// Docker daemon for every test (the real-daemon tests in
  /// `test/tools_container_test.dart` are a separate, Docker-gated group).
  final DockerProcessRunner runner;

  /// The `docker run --user` value [start] passes, e.g. `"1000:1000"`, or
  /// `null` to leave `docker/tools/Dockerfile`'s baked-in `tools` user
  /// (uid 10000) untouched. Defaults to [detectHostUserFlag]'s result;
  /// overridable so tests can inject a fixed value without shelling out to
  /// `id`, or force `null` to exercise the "no override" path explicitly
  /// (e.g. simulating Windows, where [detectHostUserFlag] itself always
  /// returns `null`). See this class's top-level "Host UID/GID mapping"
  /// doc section for the full rationale.
  final String? hostUserFlag;

  final String _normalizedHostRoot;
  final String _normalizedContainerRoot;

  String? _containerId;

  /// The running container's ID, or `null` if [start] hasn't been called (or
  /// [stop] already ran). Exposed for callers/tests that want to shell out
  /// to `docker` directly (e.g. `docker inspect`) to independently verify
  /// lifecycle state rather than trusting this class's own bookkeeping — see
  /// this PR's test plan.
  String? get containerId => _containerId;

  /// True once [start] has completed successfully and [stop] hasn't run yet.
  /// This only reflects this instance's own bookkeeping (it does not
  /// re-query the Docker daemon); see [containerId] for independent
  /// verification.
  bool get isStarted => _containerId != null;

  /// Starts a detached, long-lived container from [image], bind-mounting
  /// [hostMountRoot] (read-write; callers that need read-only mounts for a
  /// given operation should mount a narrower, purpose-specific directory —
  /// this class does not itself decide read/write policy) to
  /// [containerMountPath], and keeping it alive with `sleep infinity` (see
  /// this file's top-level doc comment on why, instead of an `ENTRYPOINT`
  /// change).
  ///
  /// Throws a [StateError] if this instance was already started, or if the
  /// `docker run` invocation fails (non-zero exit — e.g. the image doesn't
  /// exist locally, or the Docker daemon isn't reachable) — this never
  /// silently proceeds with a `null`/empty container ID.
  Future<void> start() async {
    if (_containerId != null) {
      throw StateError(
        'ToolsContainer.start() called twice; call stop() first if you '
        'need to restart the session.',
      );
    }

    final sessionLabel = _newSessionLabel();
    final result = await runner([
      'run',
      '-d',
      '--rm',
      // `sleep infinity` runs as this container's PID 1 (no shell wrapper —
      // see this file's top-level doc comment on why `sleep infinity` is
      // used at all). Linux gives PID 1 special signal-disposition
      // semantics: a signal with no explicitly installed handler is
      // *dropped*, not delivered with its normal default action — so a bare
      // `sleep infinity` as PID 1 does NOT terminate on `docker stop`'s
      // SIGTERM the way it would as a non-PID-1 process, and `docker stop`
      // would silently fall through to its full grace-period timeout (10s
      // by default) before SIGKILL on every single [stop] call. `--init`
      // runs a minimal init (tini) as the real PID 1 instead, which forwards
      // signals to `sleep infinity` with normal (non-PID-1) semantics, so
      // SIGTERM actually terminates it immediately. Verified empirically
      // during this PR's own test development: without `--init`, `docker
      // stop` on this container took the full ~10s default timeout on every
      // call; with it, well under a second.
      '--init',
      '--label',
      '$kToolsContainerSessionLabel=$sessionLabel',
      // Overrides `docker/tools/Dockerfile`'s baked-in `tools` (uid 10000)
      // user for this container instance so bind-mounted file ownership
      // matches the real host user — see this file's top-level "Host
      // UID/GID mapping" doc section. Omitted entirely (falling back to
      // the image's default user) when [hostUserFlag] is `null` (Windows,
      // or UID/GID detection failed) — never passed as an empty/malformed
      // value.
      if (hostUserFlag != null) ...['--user', hostUserFlag!],
      '-v',
      '$hostMountRoot:$containerMountPath',
      image,
      'sleep',
      'infinity',
    ]);

    if (result.exitCode != 0) {
      throw StateError(
        'Failed to start tools container from image "$image": '
        '${result.stderr.toString().trim()}',
      );
    }

    final id = result.stdout.toString().trim();
    if (id.isEmpty) {
      throw StateError(
        'docker run reported success but produced no container ID '
        '(stdout was empty) for image "$image".',
      );
    }
    _containerId = id;
  }

  /// Runs [arguments] inside the running container via `docker exec
  /// $containerId $arguments`, returning the real [ProcessResult]
  /// `docker exec` produced — the same shape `Process.run` returns
  /// (`exitCode`/`stdout`/`stderr`), so a later PR can swap a direct
  /// `Process.run(tool, args)` host call for `container.exec([tool,
  /// ...args])` with no shape change at the call site.
  ///
  /// [workingDirectory], if given, is passed as `docker exec`'s `-w` flag
  /// (a container-side absolute path — callers wanting to exec relative to a
  /// host directory should translate it first via [hostToContainerPath]).
  ///
  /// Throws a [StateError] if [start] hasn't been called yet (or [stop]
  /// already ran) — this never silently execs against a stale/absent
  /// container ID.
  Future<ProcessResult> exec(
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final id = _containerId;
    if (id == null) {
      throw StateError(
        'ToolsContainer.exec() called before start() (or after stop()); '
        'no running container to exec into.',
      );
    }
    return runner([
      'exec',
      if (workingDirectory != null) ...['-w', workingDirectory],
      id,
      ...arguments,
    ]);
  }

  /// Stops the running container and waits for it to actually be gone.
  /// Idempotent: calling this when no container is running (either [start]
  /// was never called, or [stop] already ran) is a harmless no-op, so
  /// callers can always call this unconditionally in a `finally` block (see
  /// [withSession]) without needing to track state themselves.
  ///
  /// Issues `docker stop <id>` first (a graceful SIGTERM, in case a
  /// long-running `exec` is still writing something — see this file's
  /// top-level doc comment on `--init` for why that terminates promptly
  /// rather than waiting out the default 10s grace period), then `docker rm
  /// -f $containerId` unconditionally. [start]'s `--rm` flag already schedules
  /// automatic removal once the container stops, but that removal happens
  /// asynchronously in the Docker daemon — this was verified empirically
  /// during this PR's own test development to sometimes still be in flight
  /// immediately after `docker stop` returns (a `docker inspect` run right
  /// away could still find the container). The explicit `docker rm -f` call
  /// makes removal synchronous from this method's caller's point of view: by
  /// the time [stop] returns, the container is guaranteed gone, not merely
  /// "probably about to be removed soon."
  ///
  /// Does not throw if either underlying `docker` call fails (e.g. the
  /// container already died and was removed on its own, so `docker rm -f`
  /// finds nothing) — this method's job is "make sure nothing is left
  /// running/tracked," and a failed cleanup call against an already-gone
  /// container is the success case, not a failure, from the caller's point
  /// of view. The container ID is always cleared from this instance's
  /// bookkeeping regardless of either call's exit code.
  Future<void> stop() async {
    final id = _containerId;
    if (id == null) return;
    _containerId = null;
    await runner(['stop', id]);
    await runner(['rm', '-f', id]);
  }

  /// Alias for [stop], for callers that prefer a `dispose()`-style name
  /// (e.g. if this is ever wrapped by a class following this codebase's
  /// other "start/stop a long-running external process" precedent,
  /// `pipeline_runner.dart`'s `PipelineRunner`, which does not itself use
  /// this naming but several UI-facing controllers elsewhere in `lib/`
  /// follow a `dispose()` convention).
  Future<void> dispose() => stop();

  /// Translates a host absolute path (e.g.
  /// `/mnt/target_drive/cleaning_staging/photo.jpg`) to its equivalent path
  /// inside the container (e.g. `/data/cleaning_staging/photo.jpg`), given
  /// this instance's [hostMountRoot]/[containerMountPath] bind-mount.
  ///
  /// Fails loudly — throws [ArgumentError] — rather than silently producing
  /// a wrong or truncated path, if [hostPath] is not [hostMountRoot] itself
  /// or strictly under it (per this repo's Safety Rules: a path outside the
  /// mounted root must error, never be guessed at). A path that merely
  /// shares [hostMountRoot] as a string *prefix* without a `/` boundary
  /// (e.g. `/mnt/target_drive2/...` against a root of `/mnt/target_drive`)
  /// is correctly rejected as outside the root, not accidentally accepted.
  ///
  /// [hostPath] is normalized (`.`/`..` segments resolved against a
  /// `/`-rooted walk — see [_normalizeAbsolutePath]) *before* the boundary
  /// check runs, so a traversal attempt like
  /// `/mnt/target_drive/../etc/passwd` (which is still a raw string-prefix
  /// match on `hostMountRoot` before normalization) is correctly evaluated
  /// against what it actually resolves to (`/etc/passwd`, outside the root
  /// — rejected) rather than against its unresolved literal text. A `..`
  /// that stays inside the root after normalization (e.g.
  /// `/mnt/target_drive/foo/../bar` -> `/mnt/target_drive/bar`) is not
  /// blanket-rejected just for containing `..` — only the actually-resolved
  /// destination is what's checked, matching how a real filesystem/container
  /// would resolve it.
  String hostToContainerPath(String hostPath) {
    final normalized = _normalizeAbsolutePath(hostPath, argumentName: 'hostPath');
    if (normalized == _normalizedHostRoot) return _normalizedContainerRoot;
    final prefix = '$_normalizedHostRoot/';
    if (!normalized.startsWith(prefix)) {
      throw ArgumentError.value(
        hostPath,
        'hostPath',
        'is outside the mounted root "$hostMountRoot" and cannot be '
            'translated to a container path',
      );
    }
    final relative = normalized.substring(prefix.length);
    return '$_normalizedContainerRoot/$relative';
  }

  /// The reverse of [hostToContainerPath]: translates a container-side
  /// absolute path (e.g. as it might appear in a tool's stdout/stderr — for
  /// example `exiftool` echoes back the exact path it was given on error)
  /// back to its host equivalent.
  ///
  /// Whether any given tool this container will run actually needs this is
  /// a later-PR concern (no consumer is wired up yet — see this file's
  /// top-level doc comment): `exiftool`, `ffprobe`, `rclone`, and
  /// `czkawka_cli` are all invoked with the exact path they're given and, in
  /// every case seen in `docker/tools/README.md` and the Bash scripts this
  /// pipeline already runs, echo that same path back verbatim on error
  /// (they don't resolve symlinks or rewrite it) — so a container-side
  /// `/data/...` path in a tool's own output is exactly what this function
  /// expects. This is provided now as symmetric plumbing so a future
  /// consumer PR that does need it (e.g. to show a user-facing error
  /// message with the real host path instead of the container-internal one)
  /// doesn't have to add it under time pressure.
  ///
  /// Same fail-loud contract as [hostToContainerPath]: throws
  /// [ArgumentError] if [containerPath] is not [containerMountPath] itself
  /// or strictly under it.
  ///
  /// Same normalize-before-boundary-check contract as
  /// [hostToContainerPath] — see its doc comment.
  String containerToHostPath(String containerPath) {
    final normalized = _normalizeAbsolutePath(
      containerPath,
      argumentName: 'containerPath',
    );
    if (normalized == _normalizedContainerRoot) return _normalizedHostRoot;
    final prefix = '$_normalizedContainerRoot/';
    if (!normalized.startsWith(prefix)) {
      throw ArgumentError.value(
        containerPath,
        'containerPath',
        'is outside the container mount point "$containerMountPath" and '
            'cannot be translated to a host path',
      );
    }
    final relative = normalized.substring(prefix.length);
    return '$_normalizedHostRoot/$relative';
  }

  /// Resolves `.`/`..` segments in an absolute [path] against a `/`-rooted
  /// walk, without touching the real filesystem — a pure string operation
  /// (mirroring `stitch_metadata.dart`'s `_normalizeSegments`, which solves
  /// the identical "validate a path before trusting it as a boundary check"
  /// problem for archive-extraction path-traversal guarding). Used by
  /// [hostToContainerPath]/[containerToHostPath] to normalize *before*
  /// their prefix/boundary check runs, so a traversal attempt like
  /// `<root>/../etc/passwd` is evaluated against what it actually resolves
  /// to, not its unresolved literal text (Cody/Astrid PR #93 review
  /// finding: the boundary check alone was insufficient — a `..`-laden path
  /// can pass a raw string-prefix check while still resolving outside the
  /// mounted root once a real filesystem/container processes it).
  ///
  /// A `..` that would walk above the filesystem root (e.g. `/../etc`, or
  /// more `..` segments than preceding real segments) collapses to `/`
  /// rather than underflowing, matching how `..` above `/` behaves on a
  /// real POSIX filesystem (`/` has no parent, so `cd ..` from `/` stays at
  /// `/`) — this still leaves the boundary check downstream to correctly
  /// reject it as outside the mount root; it never throws here itself, so
  /// every rejection in this class comes from the single, already-tested
  /// [ArgumentError] site in [hostToContainerPath]/[containerToHostPath].
  ///
  /// Throws [ArgumentError] (named per [argumentName]) if [path] is not
  /// itself absolute — this function is only ever called with the
  /// already-absolute-required inputs to [hostToContainerPath]/
  /// [containerToHostPath].
  static String _normalizeAbsolutePath(
    String path, {
    required String argumentName,
  }) {
    if (!path.startsWith('/')) {
      throw ArgumentError.value(
        path,
        argumentName,
        'must be an absolute path',
      );
    }
    final stack = <String>[];
    for (final segment in path.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (stack.isNotEmpty) stack.removeLast();
        continue;
      }
      stack.add(segment);
    }
    return '/${stack.join('/')}';
  }

  static final Random _sessionRandom = Random();

  /// Generates a session label unique enough to distinguish concurrent
  /// containers/orphan-cleanup runs without pulling in a UUID package
  /// (matching this repo's "no external package if the standard library
  /// suffices" posture — see `pubspec.yaml`'s deliberately short dependency
  /// list). Not a cryptographic identifier; only needs to be practically
  /// unique for `docker ps --filter label=...` bookkeeping.
  static String _newSessionLabel() {
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final rand = _sessionRandom.nextInt(0x7fffffff);
    return '$stamp-$rand';
  }

  /// Runs [body] against a freshly [start]ed container, guaranteeing [stop]
  /// runs afterward even if [body] throws — the recommended way to use this
  /// class (see this file's top-level doc comment's "Cleanup" section on why
  /// this is safer than callers manually pairing [start]/[stop]).
  static Future<T> withSession<T>({
    required String hostMountRoot,
    required Future<T> Function(ToolsContainer container) body,
    String containerMountPath = '/data',
    String image = kDefaultToolsImage,
    String dockerBin = 'docker',
    DockerProcessRunner? runner,
    // Same not-provided-vs-explicit-null sentinel as the constructor (see
    // its doc comment) — a caller that doesn't pass this at all must still
    // get auto-detection, not a forced "no --user" override.
    Object? hostUserFlag = _hostUserFlagNotProvided,
  }) async {
    final container = ToolsContainer(
      hostMountRoot: hostMountRoot,
      containerMountPath: containerMountPath,
      image: image,
      dockerBin: dockerBin,
      runner: runner,
      hostUserFlag: hostUserFlag,
    );
    await container.start();
    try {
      return await body(container);
    } finally {
      await container.stop();
    }
  }

  static DockerProcessRunner _defaultRunner(String dockerBin) {
    return (List<String> arguments) {
      return Process.run(
        dockerBin,
        arguments,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    };
  }

  /// Detects the current process's real UID/GID as a `"uid:gid"` string
  /// suitable for `docker run --user` (see this class's top-level "Host
  /// UID/GID mapping" doc section for why [start] needs this at all).
  ///
  /// Returns `null` — meaning "don't pass `--user`; leave
  /// `docker/tools/Dockerfile`'s baked-in `tools` (uid 10000) user in
  /// effect" — in two cases:
  ///
  /// - **Windows** ([Platform.isWindows]): Docker Desktop's Linux VM has a
  ///   fundamentally different bind-mount permission model than a native
  ///   Linux Docker daemon (there's no direct host-uid-to-container-uid
  ///   passthrough the way there is on Linux, and macOS's `osxfs`/`gRPC
  ///   FUSE` mount already handles ownership transparently without this
  ///   flag). Solving Windows UID mapping properly is out of scope for this
  ///   PR (#76 Phase 3 is Linux/macOS-focused; Windows end-to-end
  ///   verification is Phase 5) — detection is skipped outright here rather
  ///   than attempting (and likely mis-detecting) a UID/GID pair that
  ///   wouldn't mean the same thing there.
  /// - **`id -u`/`id -g` unavailable, erroring, or producing unexpected
  ///   output**: shouldn't happen on a real Linux/macOS host (`id` is part
  ///   of the base OS on both), but this is a permissions *optimization*,
  ///   not a safety-critical path — falling back to the image's existing
  ///   baked-in-uid behavior is strictly better than refusing to start the
  ///   tools container at all over a detection hiccup. Output is also
  ///   sanity-checked as purely numeric before use, so malformed `id`
  ///   output (e.g. from an unexpected shell alias or wrapper) can never
  ///   reach a `docker run` argument unvalidated.
  static String? detectHostUserFlag() {
    if (Platform.isWindows) return null;
    try {
      final uidResult = Process.runSync('id', ['-u']);
      final gidResult = Process.runSync('id', ['-g']);
      if (uidResult.exitCode != 0 || gidResult.exitCode != 0) return null;
      final uid = uidResult.stdout.toString().trim();
      final gid = gidResult.stdout.toString().trim();
      if (!_isNumericId(uid) || !_isNumericId(gid)) return null;
      return '$uid:$gid';
    } catch (_) {
      // `id` missing entirely, or any other Process.runSync failure (e.g.
      // permission to spawn processes at all) — fall back to "no
      // override", per this method's doc comment.
      return null;
    }
  }

  static final RegExp _numericIdPattern = RegExp(r'^\d+$');

  static bool _isNumericId(String value) =>
      value.isNotEmpty && _numericIdPattern.hasMatch(value);
}

/// The `media-pipeline-tools` image tag [ToolsContainer] runs by default.
/// Matches the local-build tag documented in `docker/tools/README.md`
/// ("Building locally" section); a registry-distributed tag
/// (`ghcr.io/leosforge-ai/media-pipeline-tools:...`) is an open Phase 1/2
/// distribution decision per that same README, not settled by this PR —
/// callers that need a different tag (registry, a pinned version, `:latest`)
/// pass [ToolsContainer.image] explicitly.
const String kDefaultToolsImage = 'media-pipeline-tools:local';

/// The `docker run --label` key [ToolsContainer.start] tags every container
/// it starts with, so orphaned containers (see this file's top-level doc
/// comment on the residual `SIGKILL` leak risk) can be found with `docker ps
/// -a --filter label=$kToolsContainerSessionLabel` independent of this
/// process's own in-memory bookkeeping.
const String kToolsContainerSessionLabel = 'media-pipeline.tools-session';

/// The seam every `docker` invocation in [ToolsContainer] goes through.
/// Mirrors this codebase's other overridable-external-tool typedefs
/// (`ExiftoolRunner` in `stitch_metadata.dart`, `VideoDurationReader` in
/// `dedupe_live_photos.dart`): the default implementation shells out for
/// real; tests inject a fake to exercise argument-building and
/// error-handling without a real Docker daemon.
typedef DockerProcessRunner =
    Future<ProcessResult> Function(List<String> arguments);
