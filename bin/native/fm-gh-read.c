/*
 * fm-gh-read - a closed, read-only front end for the hardened GitHub CLI.
 *
 * This is the authority-bearing payload for Cursor worker GitHub reads.
 * It is compiled into one native executable, enrolled as an Automic Vault
 * Launcher Bundle, and reached by Cursor workers through a protected PATH
 * directory whose `gh` router sends accepted shapes to the enrolled command.
 * All other shapes go to the generic attended GitHub CLI path.
 * bin/fm-gh-read.sh owns the build, plan, verification, and attended
 * installation contract; docs/gh-read-helper.md owns the operator guide.
 *
 * The complete parser and policy live in this file.
 * Nothing is loaded at run time: no shell, interpreter, alias, extension,
 * plugin, configuration file, or environment switch can widen what it
 * accepts, and argv[0] never selects behavior.
 *
 * Every invocation must match one complete shape from the closed table
 * below.
 * The whole argument vector is validated before anything is spawned, and on
 * the first mismatch the helper exits 64 without starting the target.
 * An accepted argument vector is passed to the absolute FM_GH_READ_TARGET
 * unchanged, with stdin from /dev/null and a constructed minimal environment;
 * nothing is inherited from the caller's environment.
 *
 * The helper does not prove who called it.
 * Any local process can invoke it and receives the same closed read API.
 */

#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef FM_GH_READ_TARGET
#define FM_GH_READ_TARGET "/usr/local/bin/gh"
#endif

#ifndef FM_GH_READ_HELPER_TARGET
#define FM_GH_READ_HELPER_TARGET "/usr/local/bin/fm-gh-read"
#endif

#define EXIT_DENIED 64
#define EXIT_INTERNAL 70
#define MAX_ARGS 64
#define MAX_ARG_BYTES 1024
#define MAX_LIMIT 1000
#define MAX_REPEAT 20

enum value_kind {
  V_NONE, /* boolean flag, takes no value */
  V_REPO,
  V_LOGIN,
  V_USER, /* login or @me */
  V_NUMBER,
  V_LIMIT,
  V_FIELDS,
  V_TEXT,
  V_PR_STATE,
  V_ISSUE_STATE,
  V_RUN_STATUS,
  V_VISIBILITY,
  V_EVENT,
  V_SHA,
  V_ISSUE_SORT,
};

struct option_spec {
  const char *name;
  enum value_kind kind;
  int max_count;
};

enum positional_rule {
  POS_NONE,
  POS_OPTIONAL,
  POS_REQUIRED,
  POS_OR_JOB, /* optional positional, but it or --job is required */
};

#define MAX_OPTIONS 12

struct shape {
  const char *family;
  const char *verb;
  enum positional_rule positional;
  enum value_kind positional_kind;
  struct option_spec options[MAX_OPTIONS];
};

#ifdef FM_GH_READ_ROUTER
static char **route_argv;

static _Noreturn void route_to(const char *target) {
  route_argv[0] = "gh";
  execv(target, route_argv);
  fprintf(stderr, "fm-gh-read-route: cannot start %s: %s\n", target,
          strerror(errno));
  exit(EXIT_INTERNAL);
}
#endif

static const struct shape SHAPES[] = {
    {"repo", "view", POS_REQUIRED, V_REPO, {{"--json", V_FIELDS, 1}}},
    {"pr",
     "list",
     POS_NONE,
     V_NONE,
     {{"--json", V_FIELDS, 1},
      {"--state", V_PR_STATE, 1},
      {"--limit", V_LIMIT, 1},
      {"--label", V_TEXT, MAX_REPEAT},
      {"--assignee", V_USER, 1},
      {"--author", V_USER, 1},
      {"--base", V_TEXT, 1},
      {"--head", V_TEXT, 1},
      {"--draft", V_NONE, 1},
      {"--repo", V_REPO, 1}}},
    {"pr",
     "view",
     POS_REQUIRED,
     V_NUMBER,
     {{"--json", V_FIELDS, 1}, {"--repo", V_REPO, 1}}},
    {"pr",
     "checks",
     POS_REQUIRED,
     V_NUMBER,
     {{"--json", V_FIELDS, 1},
      {"--required", V_NONE, 1},
      {"--repo", V_REPO, 1}}},
    {"issue",
     "list",
     POS_NONE,
     V_NONE,
     {{"--json", V_FIELDS, 1},
      {"--state", V_ISSUE_STATE, 1},
      {"--limit", V_LIMIT, 1},
      {"--label", V_TEXT, MAX_REPEAT},
      {"--assignee", V_USER, 1},
      {"--author", V_USER, 1},
      {"--milestone", V_TEXT, 1},
      /* gh-axi --sort created|updated|comments becomes this closed form.
       * Free-form search is denied. */
      {"--search", V_ISSUE_SORT, 1},
      {"--repo", V_REPO, 1}}},
    {"issue",
     "view",
     POS_REQUIRED,
     V_NUMBER,
     {{"--json", V_FIELDS, 1}, {"--repo", V_REPO, 1}}},
    {"run",
     "list",
     POS_NONE,
     V_NONE,
     {{"--json", V_FIELDS, 1},
      {"--limit", V_LIMIT, 1},
      {"--workflow", V_TEXT, 1},
      {"--branch", V_TEXT, 1},
      {"--status", V_RUN_STATUS, 1},
      {"--event", V_EVENT, 1},
      {"--user", V_USER, 1},
      {"--commit", V_SHA, 1},
      {"--repo", V_REPO, 1}}},
    {"run",
     "view",
     POS_OR_JOB,
     V_NUMBER,
     {{"--job", V_NUMBER, 1}, {"--json", V_FIELDS, 1}, {"--repo", V_REPO, 1}}},
    {"workflow",
     "list",
     POS_NONE,
     V_NONE,
     {{"--json", V_FIELDS, 1},
      {"--limit", V_LIMIT, 1},
      {"--all", V_NONE, 1},
      {"--repo", V_REPO, 1}}},
    {"workflow", "view", POS_REQUIRED, V_TEXT, {{"--repo", V_REPO, 1}}},
};

static void deny(const char *reason, const char *arg) {
#ifdef FM_GH_READ_ROUTER
  (void)reason;
  (void)arg;
  route_to(FM_GH_READ_TARGET);
#else
  if (arg != NULL) {
    fprintf(stderr, "fm-gh-read: denied: %s: %.80s\n", reason, arg);
  } else {
    fprintf(stderr, "fm-gh-read: denied: %s\n", reason);
  }
  fprintf(stderr,
          "fm-gh-read: only closed read-only repo, pr, issue, run, and "
          "workflow shapes are accepted; see docs/gh-read-helper.md\n");
  exit(EXIT_DENIED);
#endif
}

static int is_alnum(char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
         (c >= '0' && c <= '9');
}

static int is_one_of(const char *value, const char *const *choices) {
  for (; *choices != NULL; choices++) {
    if (strcmp(value, *choices) == 0) {
      return 1;
    }
  }
  return 0;
}

/* A GitHub login: 1-39 ASCII letters, digits, or single interior hyphens. */
static int valid_login(const char *s, size_t len) {
  size_t i;
  if (len < 1 || len > 39 || s[0] == '-' || s[len - 1] == '-') {
    return 0;
  }
  for (i = 0; i < len; i++) {
    if (s[i] == '-') {
      if (s[i + 1] == '-') {
        return 0;
      }
    } else if (!is_alnum(s[i])) {
      return 0;
    }
  }
  return 1;
}

/* A canonical owner/name selector with no host, scheme, or .git suffix. */
static int valid_repo(const char *s) {
  const char *slash = strchr(s, '/');
  const char *name;
  size_t name_len, i;
  if (slash == NULL || strchr(slash + 1, '/') != NULL) {
    return 0;
  }
  if (!valid_login(s, (size_t)(slash - s))) {
    return 0;
  }
  name = slash + 1;
  name_len = strlen(name);
  if (name_len < 1 || name_len > 100 || strcmp(name, ".") == 0 ||
      strcmp(name, "..") == 0 || name[0] == '-') {
    return 0;
  }
  if (name_len >= 4 && strcmp(name + name_len - 4, ".git") == 0) {
    return 0;
  }
  for (i = 0; i < name_len; i++) {
    if (!is_alnum(name[i]) && name[i] != '-' && name[i] != '_' &&
        name[i] != '.') {
      return 0;
    }
  }
  return 1;
}

/* A positive decimal identifier with no sign, space, or leading zero. */
static int valid_number(const char *s) {
  size_t i, len = strlen(s);
  if (len < 1 || len > 19 || s[0] == '0') {
    return 0;
  }
  for (i = 0; i < len; i++) {
    if (s[i] < '0' || s[i] > '9') {
      return 0;
    }
  }
  return 1;
}

static int valid_limit(const char *s) {
  return valid_number(s) && strlen(s) <= 4 && atoi(s) <= MAX_LIMIT;
}

/* A comma-separated list of JSON field names such as number,title,state. */
static int valid_fields(const char *s) {
  size_t i, run = 0, count = 1, len = strlen(s);
  if (len < 1 || len > 512) {
    return 0;
  }
  for (i = 0; i < len; i++) {
    char c = s[i];
    if (c == ',') {
      if (run == 0) {
        return 0;
      }
      run = 0;
      count++;
    } else if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
      run++;
      if (run > 64) {
        return 0;
      }
    } else {
      return 0;
    }
  }
  return run > 0 && count <= 64;
}

/*
 * Free text such as a label, branch, milestone, or workflow name.
 * It may not look like an option and may not carry control bytes.
 */
static int valid_text(const char *s) {
  size_t i, len = strlen(s);
  if (len < 1 || len > 256 || s[0] == '-') {
    return 0;
  }
  for (i = 0; i < len; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c < 0x20 || c == 0x7f) {
      return 0;
    }
  }
  return 1;
}

static int valid_event(const char *s) {
  size_t i, len = strlen(s);
  if (len < 1 || len > 64) {
    return 0;
  }
  for (i = 0; i < len; i++) {
    if (!((s[i] >= 'a' && s[i] <= 'z') || s[i] == '_')) {
      return 0;
    }
  }
  return 1;
}

static int valid_sha(const char *s) {
  size_t i, len = strlen(s);
  if (len < 7 || len > 40) {
    return 0;
  }
  for (i = 0; i < len; i++) {
    if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) {
      return 0;
    }
  }
  return 1;
}

static int valid_value(enum value_kind kind, const char *s) {
  static const char *const pr_states[] = {"open", "closed", "merged", "all",
                                          NULL};
  static const char *const issue_states[] = {"open", "closed", "all", NULL};
  static const char *const run_statuses[] = {
      "queued",    "completed", "in_progress",     "requested", "waiting",
      "pending",   "action_required", "cancelled", "failure",   "neutral",
      "skipped",   "stale",     "startup_failure", "success",   "timed_out",
      NULL};
  static const char *const visibilities[] = {"public", "private", "internal",
                                             NULL};
  static const char *const issue_sorts[] = {
      "sort:created-desc", "sort:updated-desc", "sort:comments-desc", NULL};
  switch (kind) {
  case V_REPO:
    return valid_repo(s);
  case V_LOGIN:
    return valid_login(s, strlen(s));
  case V_USER:
    return strcmp(s, "@me") == 0 || valid_login(s, strlen(s));
  case V_NUMBER:
    return valid_number(s);
  case V_LIMIT:
    return valid_limit(s);
  case V_FIELDS:
    return valid_fields(s);
  case V_TEXT:
    return valid_text(s);
  case V_PR_STATE:
    return is_one_of(s, pr_states);
  case V_ISSUE_STATE:
    return is_one_of(s, issue_states);
  case V_RUN_STATUS:
    return is_one_of(s, run_statuses);
  case V_VISIBILITY:
    return is_one_of(s, visibilities);
  case V_EVENT:
    return valid_event(s);
  case V_SHA:
    return valid_sha(s);
  case V_ISSUE_SORT:
    return is_one_of(s, issue_sorts);
  case V_NONE:
    break;
  }
  return 0;
}

static const struct shape *find_shape(const char *family, const char *verb) {
  size_t i;
  for (i = 0; i < sizeof(SHAPES) / sizeof(SHAPES[0]); i++) {
    if (strcmp(SHAPES[i].family, family) == 0 &&
        strcmp(SHAPES[i].verb, verb) == 0) {
      return &SHAPES[i];
    }
  }
  return NULL;
}

/* Validate the complete argument vector or exit without returning. */
static void validate(int argc, char **argv) {
  const struct shape *shape;
  int counts[MAX_OPTIONS] = {0};
  int i, have_positional = 0, have_job = 0, have_repo = 0;

  if (argc < 3) {
    deny("a family and read verb are required", NULL);
  }
  if (argc - 1 > MAX_ARGS) {
    deny("too many arguments", NULL);
  }
  for (i = 1; i < argc; i++) {
    if (strlen(argv[i]) > MAX_ARG_BYTES) {
      deny("argument too long", NULL);
    }
  }
  shape = find_shape(argv[1], argv[2]);
  if (shape == NULL) {
    deny("unsupported command", argv[1]);
  }

  for (i = 3; i < argc; i++) {
    const char *arg = argv[i];
    if (arg[0] == '-') {
      int o, found = -1;
      for (o = 0; o < MAX_OPTIONS && shape->options[o].name != NULL; o++) {
        if (strcmp(arg, shape->options[o].name) == 0) {
          found = o;
          break;
        }
      }
      if (found < 0) {
        deny("unsupported option", arg);
      }
      if (++counts[found] > shape->options[found].max_count) {
        deny("duplicate option", arg);
      }
      if (shape->options[found].kind == V_NONE) {
        continue;
      }
      if (i + 1 >= argc) {
        deny("option requires a value", arg);
      }
      if (!valid_value(shape->options[found].kind, argv[i + 1])) {
        deny("invalid option value", arg);
      }
      if (shape->options[found].kind == V_REPO) {
        have_repo = 1;
      }
      if (strcmp(arg, "--job") == 0) {
        have_job = 1;
      }
      i++;
    } else {
      if (shape->positional == POS_NONE) {
        deny("unexpected argument", arg);
      }
      if (have_positional) {
        deny("duplicate selector", arg);
      }
      if (!valid_value(shape->positional_kind, arg)) {
        deny("invalid selector", arg);
      }
      have_positional = 1;
      if (shape->positional_kind == V_REPO) {
        have_repo = 1;
      }
    }
  }

  if (shape->positional == POS_REQUIRED && !have_positional) {
    deny("a selector is required", argv[2]);
  }
  if (shape->positional == POS_OR_JOB && !have_positional && !have_job) {
    deny("a run id or --job is required", argv[2]);
  }
  if (!have_repo) {
    deny("a canonical owner/name repository selector is required", argv[2]);
  }
}

static pid_t child_pid = -1;

static void forward_signal(int sig) {
  if (child_pid > 0) {
    kill(child_pid, sig);
  }
}

static char *env_entry(const char *key, const char *value) {
  size_t len = strlen(key) + strlen(value) + 2;
  char *entry = malloc(len);
  if (entry == NULL) {
    fprintf(stderr, "fm-gh-read: out of memory\n");
    exit(EXIT_INTERNAL);
  }
  snprintf(entry, len, "%s=%s", key, value);
  return entry;
}

int main(int argc, char **argv) {
  const char *target = FM_GH_READ_TARGET;
  struct passwd *pw;
  char *child_argv[MAX_ARGS + 2];
  char *child_env[16];
  int n = 0, i, status;
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attr;
  sigset_t no_signals, default_signals;
  short flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
  struct sigaction sa;

#ifdef FM_GH_READ_ROUTER
  route_argv = argv;
#endif
  validate(argc, argv);

#ifdef FM_GH_READ_ROUTER
  route_to(FM_GH_READ_HELPER_TARGET);
#endif

  if (target[0] != '/') {
    fprintf(stderr, "fm-gh-read: build error: target is not absolute\n");
    return EXIT_INTERNAL;
  }

  /* HOME and the user name come from the account database, never the
   * caller's environment, so a caller cannot point the target at another
   * configuration directory. */
  pw = getpwuid(getuid());
  if (pw == NULL || pw->pw_dir == NULL || pw->pw_dir[0] != '/' ||
      pw->pw_name == NULL) {
    fprintf(stderr, "fm-gh-read: cannot resolve the current account\n");
    return EXIT_INTERNAL;
  }
  child_env[n++] = env_entry("HOME", pw->pw_dir);
  child_env[n++] = env_entry("USER", pw->pw_name);
  child_env[n++] = env_entry("LOGNAME", pw->pw_name);
  child_env[n++] = env_entry("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
  child_env[n++] = env_entry("GH_PAGER", "");
  child_env[n++] = env_entry("GH_PROMPT_DISABLED", "1");
  child_env[n++] = env_entry("GH_NO_UPDATE_NOTIFIER", "1");
  child_env[n++] = env_entry("GH_NO_EXTENSION_UPDATE_NOTIFIER", "1");
  child_env[n++] = env_entry("GH_SPINNER_DISABLED", "1");
  child_env[n] = NULL;

  child_argv[0] = "gh";
  for (i = 1; i < argc; i++) {
    child_argv[i] = argv[i];
  }
  child_argv[argc] = NULL;

  if (posix_spawn_file_actions_init(&actions) != 0 ||
      posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) !=
          0 ||
      posix_spawnattr_init(&attr) != 0) {
    fprintf(stderr, "fm-gh-read: cannot prepare the target\n");
    return EXIT_INTERNAL;
  }
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
  /* Close every inherited descriptor except stdout and stderr. */
  flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
  if (posix_spawn_file_actions_addinherit_np(&actions, 1) != 0 ||
      posix_spawn_file_actions_addinherit_np(&actions, 2) != 0) {
    fprintf(stderr, "fm-gh-read: cannot prepare the target\n");
    return EXIT_INTERNAL;
  }
#endif
  sigemptyset(&no_signals);
  sigfillset(&default_signals);
  if (posix_spawnattr_setsigmask(&attr, &no_signals) != 0 ||
      posix_spawnattr_setsigdefault(&attr, &default_signals) != 0 ||
      posix_spawnattr_setflags(&attr, flags) != 0) {
    fprintf(stderr, "fm-gh-read: cannot prepare the target\n");
    return EXIT_INTERNAL;
  }

  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = forward_signal;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGHUP, &sa, NULL);

  status = posix_spawn(&child_pid, target, &actions, &attr, child_argv,
                       child_env);
  if (status != 0) {
    fprintf(stderr, "fm-gh-read: cannot start %s: %s\n", target,
            strerror(status));
    return EXIT_INTERNAL;
  }

  while (waitpid(child_pid, &status, 0) < 0) {
    if (errno != EINTR) {
      fprintf(stderr, "fm-gh-read: lost the target process\n");
      return EXIT_INTERNAL;
    }
  }
  if (WIFEXITED(status)) {
    return WEXITSTATUS(status);
  }
  if (WIFSIGNALED(status)) {
    return 128 + WTERMSIG(status);
  }
  return EXIT_INTERNAL;
}
