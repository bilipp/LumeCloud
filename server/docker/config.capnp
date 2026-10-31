# workerd configuration for running Lume Cloud in Docker (see ../Dockerfile).
# It mirrors the top-level bindings of ../wrangler.jsonc; keep the two in sync
# when adding a binding, a Durable Object class or changing a rate limit.

using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    (name = "main", worker = .lumeCloud),
    # SQLite files of every Durable Object (one per account, pairing, guard).
    (name = "storage", disk = (path = "/data", writable = true)),
  ],
  sockets = [(name = "http", address = "*:8787", http = (), service = "main")],
  extensions = [(
    modules = [(name = "lume-internal:ratelimit", esModule = embed "ratelimit.js", internal = true)],
  )],
);

const lumeCloud :Workerd.Worker = (
  modules = [(name = "index.js", esModule = embed "dist/index.js")],
  compatibilityDate = "2026-10-19",

  # uniqueKey names each class's directory under /data and seeds its object
  # ids. Never change it on a live instance: every account would be lost.
  durableObjectNamespaces = [
    (className = "AccountDO", uniqueKey = "lume-cloud-AccountDO", enableSql = true),
    (className = "PairingDO", uniqueKey = "lume-cloud-PairingDO", enableSql = true),
    (className = "SignupGuardDO", uniqueKey = "lume-cloud-SignupGuardDO", enableSql = true),
  ],
  durableObjectStorage = (localDisk = "storage"),

  bindings = [
    (name = "ACCOUNT", durableObjectNamespace = (className = "AccountDO")),
    (name = "PAIRING", durableObjectNamespace = (className = "PairingDO")),
    (name = "SIGNUP_GUARD", durableObjectNamespace = (className = "SignupGuardDO")),

    (name = "SIGNUP", fromEnvironment = "SIGNUP"),
    (name = "INVITE_CODE", fromEnvironment = "INVITE_CODE"),
    (name = "VERSION", fromEnvironment = "VERSION"),
    # workerd has no jurisdictions; data stays wherever the volume lives.
    (name = "DO_JURISDICTION", text = "none"),

    (name = "RL_SIGNUP", wrapped = (moduleName = "lume-internal:ratelimit", innerBindings = [
      (name = "namespace", text = "signup"), (name = "limit", json = "5"), (name = "period", json = "60")])),
    (name = "RL_PAIRING_CREATE", wrapped = (moduleName = "lume-internal:ratelimit", innerBindings = [
      (name = "namespace", text = "pairing-create"), (name = "limit", json = "10"), (name = "period", json = "60")])),
    (name = "RL_PAIRING_LOOKUP", wrapped = (moduleName = "lume-internal:ratelimit", innerBindings = [
      (name = "namespace", text = "pairing-lookup"), (name = "limit", json = "10"), (name = "period", json = "60")])),
    (name = "RL_ACCOUNT", wrapped = (moduleName = "lume-internal:ratelimit", innerBindings = [
      (name = "namespace", text = "account"), (name = "limit", json = "300"), (name = "period", json = "60")])),
    (name = "RL_PAIRING_POLL", wrapped = (moduleName = "lume-internal:ratelimit", innerBindings = [
      (name = "namespace", text = "pairing-poll"), (name = "limit", json = "120"), (name = "period", json = "60")])),
  ],
);
