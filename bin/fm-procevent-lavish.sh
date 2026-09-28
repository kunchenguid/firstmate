#!/usr/bin/env bash
# Read-only compatibility adapter for results captured by retired Lavish sources.
#
# Usage:
#   fm-procevent-lavish.sh retire-registered
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh silent <result-file>
#   fm-procevent-lavish.sh answers <result-file>
#   fm-procevent-lavish.sh reconciles <result-file>
#   fm-procevent-lavish.sh read <result-file>
#
# retire-registered
#            Retire every legacy built-in Lavish registration in this home by
#            exact registration identity. Captured result files remain intact,
#            pending results remain announced, and their decision binding is
#            retained until the final captured generation is acknowledged.
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, missing, or unknown.
# read       Print a structured presentation of one already-captured result so a
#            handler consumes every queued item without grepping the raw file.
#            It is read-only over the capture: it does not arm, poll, or change
#            what Lavish delivered. The session-ending freeform message
#            (tag=message) is its own labeled field, printed first and distinct
#            from per-element annotations. Declared and presented item counts,
#            plus a completeness verdict, follow before all annotations so a
#            partial read is obvious. Each annotation retains its element uid,
#            selector, tag, and text. A non-choice freeform comment (`prompt`)
#            is printed as its own field even when a selector is also present
#            and even when that comment matches the element text, so typed
#            words are never dropped. Choice Context data is not a comment.
#            Captain-supplied body lines are visibly prefixed so they cannot
#            forge structural labels. Empty message and annotation sections
#            are reported explicitly.
# terminal   Exit 0 when the captured result means this Lavish source will never
#            produce another result, so the runner may retire it; any other exit
#            keeps it armed. This is the generic adapter contract bin/fm-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
# silent     Exit 0 when the captured result is a routine no-op the runner should
#            record and never announce; any other exit publishes the wake. This
#            is the generic no-op contract bin/fm-procevent.sh calls, and the
#            only place Lavish's notion of "nothing was said" is decided.
#
# AN EMPTY BOARD CLOSE IS NOT NEWS, and that is what `silent` exists to say.
# Closing a review surface that carried nothing is the single most common Lavish
# result: the captain reads a board, says nothing, and closes it. Announcing that
# put a wake in front of the handler whose entire content was that nothing
# happened. `silent` therefore holds one narrow, positively-determined shape -
# a session this adapter classifies `ended` that carries no queued content block
# at all - and every other result stays announced.
#
# Deliberately narrow, in both directions. A `Send & End` close carrying the
# captain's actual answer arrives as `status: feedback` with `session_ended`, so
# it classifies `feedback`, never `ended`, and is announced exactly as before; so
# is any `ended` result that still carries a `prompts` or `feedback` block, which
# the published poll is not expected to produce but which must never be dropped
# on that expectation. A `waiting` session, a `missing` one, an `unknown` or
# unreadable result, and any error all stay announced, because none of them
# positively proves nothing was said. Silence is only ever an absence this
# adapter can see in the result, never an absence it assumes.
#
# This compatibility adapter cannot arm or poll a source and has no dependency
# on lavish-axi. It exists only so homes upgraded with old registrations or
# captures converge safely without losing already captured feedback.
#
# `answers` is this adapter's half of the generic keyed-answer contract in
# bin/fm-procevent.sh. It reports what the captain actually chose, as
# `<task-id>\t<answer>\t<label>` lines, and stops there. It maps nothing to a
# task, records no decision, and closes nothing: a captain answer is not special
# to Lavish, so every rule about what a keyed answer DOES belongs to the one
# intake in bin/fm-captain-hold.sh, which the runner feeds. A Lavish review is
# just an ephemeral discussion format that happens to carry answers.
#
# Only rows tagged `choice` are read. A freeform captain message is prose that may
# contain anything, and must never be able to forge a decision key.
#
# `read` is the presentation command summarized above; keyed intake remains
# the separate `answers` contract described here.
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

cmd_retire_registered() {
  local registry rec id argc line_no=0 retired=0
  local -a argv=()
  [ "$#" -eq 0 ] || usage
  registry=$(fm_procevent_registry_dir "$STATE")
  [ -d "$registry" ] && [ ! -L "$registry" ] || return 0
  for rec in "$registry"/*.source; do
    [ -e "$rec" ] || continue
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    [ "$(sed -n '1p' "$rec")" = adapter=lavish ] || continue
    id=${rec##*/}
    id=${id%.source}
    fm_procevent_source_id_valid "$id" || continue
    argc=$(sed -n 's/^argc=//p' "$rec" | head -1)
    case "$argc" in ''|*[!0-9]*) continue ;; esac
    argv=()
    line_no=0
    while IFS= read -r line; do
      line_no=$((line_no + 1))
      [ "$line_no" -le "$argc" ] && argv+=("$line")
    done < <(sed -n '/^argv:$/,$p' "$rec" | tail -n +2)
    [ "${#argv[@]}" -eq "$argc" ] || continue
    "$SCRIPT_DIR/fm-procevent.sh" retire "$id" --if-matches lavish -- "${argv[@]}" >/dev/null \
      || die "cannot safely retire legacy Lavish source: $id"
    retired=$((retired + 1))
  done
  [ "$retired" -eq 0 ] || printf 'BOOTSTRAP_INFO: retired legacy Lavish sources: %s\n' "$retired"
}

# Read one field of the response's leading `session:` block. Those fields are
# INDENTED, so each is read as the first indented match inside that block rather
# than an anchored whole-line match; anchoring on "^status:" silently never
# matches and treats every ended review as feedback. Confining the read to the
# leading block is also what stops prompt payload text from forging a session
# field. <field> is a fixed field name supplied by this adapter, never by input.
session_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z_]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

# Classify a completed result into a lifecycle state for the handler.
cmd_classify() {
  local file=${1-} status error_code error_message
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(session_field "$file" status)
  case "$status" in
    feedback) printf 'feedback\n'; return 0 ;;
    ended)    printf 'ended\n'; return 0 ;;
    waiting)  printf 'waiting\n'; return 0 ;;
  esac
  error_message=$(awk 'NR == 1 && /^error:[[:space:]]*/ { sub(/^error:[[:space:]]*/, ""); print }' "$file")
  error_code=$(awk '
    NR == 1 && /^error:[[:space:]]*/ { in_error=1; next }
    in_error && /^code:[[:space:]]*[A-Z_]+[[:space:]]*$/ {
      sub(/^code:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
    in_error { exit }
  ' "$file")
  if [ "$error_code" = NOT_FOUND ] || [[ "$error_message" == "No active Lavish Editor session"* ]]; then
    printf 'missing\n'
  else
    printf 'unknown\n'
  fi
}

# Whether a captured result ends this source, for the generic runner's automatic
# retirement. Lavish's notion of "ended" lives here and nowhere else: an ended
# session produces nothing further, a missing session has nothing left to
# produce, and the published poll delivers the final feedback of a `Send & End`
# review marked with session_ended and returns only empty ended sessions after
# it. Anything else - including an unreadable result - keeps the source armed.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(cmd_classify "$file")" in
    ended|missing) return 0 ;;
  esac
  case "$(session_field "$file" session_ended)" in
    true|True|TRUE) return 0 ;;
  esac
  return 1
}

# Whether a completed result carries any queued content block at all. The
# published response frames content as a top-level `prompts[N]{...}:` or
# `feedback[N]{...}:` header whose rows are INDENTED, so this anchors on column
# zero: an indented payload line is captain-supplied text and must never be able
# to forge - or, here, to hide behind - a content header. Any recognized block
# is content regardless of its declared count, while a malformed top-level
# prompts or feedback header makes the result indeterminate.
#
# 0 = content present, 1 = provably no content, anything else = the check did
# not complete. The caller must distinguish those three, because "the check
# failed" is never proof that nothing was said.
result_has_queued_content() {  # <result-file>
  awk '
    /^(prompts|feedback)\[[0-9]+\]\{[^}]*\}:[[:space:]]*$/ {
      verdict = "present"
      exit
    }
    /^(prompts|feedback)/ {
      verdict = "indeterminate"
      exit
    }
    END {
      if (verdict == "present") exit 0
      if (verdict == "indeterminate") exit 2
      exit 1
    }
  ' "$1"
}

# Whether a captured result is a routine no-op the runner should record without
# announcing, for the generic runner's silence seam. Lavish's notion of "nothing
# was said" lives here and nowhere else: an ended session carrying no queued
# content block is a board the captain closed without saying anything, and the
# handler learns nothing from being told. Anything else - a real answer, a
# missing or waiting session, an unreadable result - is announced.
cmd_silent() {
  local file=${1-} content_rc
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" = ended ] || return 1
  result_has_queued_content "$file"
  content_rc=$?
  # Only a completed check that proved the result carries nothing declares
  # silence; a check that could not complete announces, like every other
  # uncertainty here.
  [ "$content_rc" -eq 1 ]
}

# Print `key<TAB>answer<TAB>label[<TAB>mode]` for each non-reconcile structured choice the
# captain submitted in a captured result; the optional mode column relays the
# card's declared close mode (`done` or `release`) to the keyed-answer intake. The published response frames queued feedback as
# a `prompts[N]{field,...}:` header followed by exactly N indented CSV rows whose
# quoted fields carry JSON-style escapes, so this reads the declared field ORDER
# rather than assuming a fixed column, and takes only rows whose `tag` field is
# `choice`. A freeform `message` row is captain prose and is deliberately never a
# source of decision keys. A row that does not carry both a slug-shaped `question`
# and the versioned `selection` and `note` fields inside its `Context data:` block
# is skipped. A time-limited rollout branch accepts the old question/answer
# shape only for ordinary answers and rejects its bare or annotated reconcile
# values because old rows do not separate the selected option from its note.
# The question cap is 128 so any task id fits, including the long legacy
# `<origin>-decision-<key>` identities pre-collapse decks still carry; the
# security property is the slug SHAPE, which is unchanged.
cmd_choice_rows() {
  local selection=$1 file=${2-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($selection, $path) = @ARGV;
    open my $fh, "<", $path or exit 1;
    my (@fields, $want, @rows);
    while (my $line = <$fh>) {
      if (!@fields) {
        next unless $line =~ /^prompts\[(\d+)\]\{([^}]*)\}:\s*$/;
        ($want, @fields) = ($1, split /,/, $2);
        next;
      }
      last unless $line =~ /^\s/;
      last if @rows >= $want;
      chomp $line;
      push @rows, $line;
    }
    close $fh;
    my %seen;
    my @choices;
    for my $row (@rows) {
      $row =~ s/^\s+//;
      my @vals;
      while (length $row) {
        if ($row =~ s/^"((?:[^"\\]|\\.)*)"//) {
          my $v = $1;
          $v =~ s/\\(.)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : $1 eq "r" ? "\r" : $1/ge;
          push @vals, $v;
        } else {
          $row =~ s/^([^,]*)//;
          push @vals, $1;
        }
        last unless $row =~ s/^,//;
      }
      my %f;
      $f{$fields[$_]} = $vals[$_] for 0 .. $#fields;
      next unless defined $f{tag} && $f{tag} eq "choice";
      my $prompt = $f{prompt};
      next unless defined $prompt && $prompt =~ /Context data:\s*(\{.*\})/s;
      my $ctx = $1;
      my $data = eval { decode_json($ctx) };
      next unless ref($data) eq "HASH";
      my ($key, $selected, $note, $answer, $legacy);
      if (defined($data->{schema}) && !ref($data->{schema})
          && $data->{schema} eq "fm-bearings-answer.v1") {
        $key = $data->{question};
        $selected = $data->{selection};
        $note = $data->{note};
        next if !defined($key) || ref($key) || !defined($selected) || ref($selected)
          || !defined($note) || ref($note);
        next unless $selected eq "" || $selected =~ /\A[A-Za-z0-9._-]{1,128}\z/;
        next unless length($note) <= 512;
        next unless length($selected) || length($note);
        $answer = length($selected) ? $selected : $note;
        $legacy = 0;
      # Time-limited compatibility for captures from pre-change boards; remove
      # once no board carrying the old question/answer context can remain armed.
      } elsif (!exists($data->{schema}) && !exists($data->{selection})
          && !exists($data->{note})) {
        $key = $data->{question};
        $answer = $data->{answer};
        next if !defined($key) || ref($key) || !defined($answer) || ref($answer);
        next unless length($answer) && length($answer) <= 512;
        next if $answer eq "reconcile" || index($answer, "reconcile - ") == 0;
        $selected = "";
        $note = "";
        $legacy = 1;
      } else {
        next;
      }
      next unless $key =~ /\A[A-Za-z0-9._-]{1,128}\z/;
      my $mode = "";
      if (exists $data->{close}) {
        next if !defined($data->{close}) || ref($data->{close})
          || ($data->{close} ne "done" && $data->{close} ne "release");
        $mode = $data->{close};
      }
      my $label = defined $f{text} ? $f{text} : "";
      s/[\x00-\x1f\x7f]/ /g for ($answer, $note, $label);
      $label = substr($label, 0, 512);
      if (defined $seen{$key}) { $choices[$seen{$key}] = undef }
      $seen{$key} = scalar @choices;
      push @choices, {
        key => $key, selection => $selected, note => $note, legacy => $legacy,
        answer => $answer, label => $label, mode => $mode
      };
    }
    for my $choice (grep { defined } @choices) {
      if ($selection eq "reconciles") {
        next if $choice->{legacy};
        if ($choice->{selection} eq "reconcile") {
          print length($choice->{note})
            ? "$choice->{key}\t$choice->{note}\n"
            : "$choice->{key}\n";
        }
        next;
      }
      next if $choice->{selection} eq "reconcile";
      print length $choice->{mode}
        ? "$choice->{key}\t$choice->{answer}\t$choice->{label}\t$choice->{mode}\n"
        : "$choice->{key}\t$choice->{answer}\t$choice->{label}\n";
    }
  ' "$selection" "$file"
}

cmd_answers() { cmd_choice_rows answers "$@"; }
cmd_reconciles() { cmd_choice_rows reconciles "$@"; }

# Present one already-captured result for a handler. Body lines are prefixed
# so a captain-supplied string cannot forge a section label. The session-ending
# message is printed before the count line and before any annotation, because
# that is the field a truncated grep of the raw capture historically dropped.
# A non-choice annotation that carries a freeform `prompt` prints that comment
# as its own field; a selector must not hide the typed words, even when the
# comment matches the captured element text. Choice rows keep Context data
# out of that field. A pure annotation has no prompt.
cmd_read() {
  local file=${1-} lifecycle session_ended
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  lifecycle=$(cmd_classify "$file")
  session_ended=$(session_field "$file" session_ended)
  perl -e '
    use strict; use warnings;
    my ($path, $lifecycle, $session_ended) = @ARGV;
    open my $fh, "<", $path or exit 1;
    my (@fields, $want, @rows);
    while (my $line = <$fh>) {
      if (!@fields) {
        next unless $line =~ /^(?:prompts|feedback)\[(\d+)\]\{([^}]*)\}:\s*$/;
        ($want, @fields) = ($1, split /,/, $2);
        next;
      }
      last unless $line =~ /^\s/;
      last if defined($want) && @rows >= $want;
      chomp $line;
      push @rows, $line;
    }
    close $fh;
    $want = 0 unless defined $want;
    my @parsed;
    my $malformed = 0;
    for my $row (@rows) {
      $row =~ s/^\s+//;
      my @vals;
      while (length $row) {
        if ($row =~ s/^"((?:[^"\\]|\\.)*)"//) {
          push @vals, $1;
        } else {
          $row =~ s/^([^,]*)//;
          push @vals, $1;
        }
        last unless $row =~ s/^,//;
      }
      if (@vals > @fields) {
        my ($preserve) = grep { $fields[$_] eq "prompt" } 0 .. $#fields;
        ($preserve) = grep { $fields[$_] eq "text" } 0 .. $#fields unless defined $preserve;
        if (defined $preserve) {
          my $count = @vals - @fields + 1;
          my @parts = splice @vals, $preserve, $count;
          splice @vals, $preserve, 0, join(",", @parts);
        }
      }
      if (@vals != @fields) {
        $malformed++;
        next;
      }
      s/\\(.)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : $1 eq "r" ? "\r" : $1/ge for @vals;
      my %f;
      $f{$fields[$_]} = $vals[$_] for 0 .. $#fields;
      push @parsed, \%f;
    }
    my $presented = scalar @parsed;
    my $complete = ($presented == $want && !$malformed) ? "yes" : "no";
    my @messages;
    my @annotations;
    for my $f (@parsed) {
      my $tag = defined $f->{tag} ? $f->{tag} : "";
      if ($tag eq "message") {
        push @messages, $f;
      } else {
        push @annotations, $f;
      }
    }
    sub emit_body {
      my ($text) = @_;
      $text = "" unless defined $text;
      $text =~ s/\r\n/\n/g;
      $text =~ s/\r/\n/g;
      my @lines = split /\n/, $text, -1;
      pop @lines if @lines && $lines[-1] eq "";
      return if !@lines || (@lines == 1 && $lines[0] eq "");
      print "| $_\n" for @lines;
    }
    if (@messages) {
      print "SESSION-ENDING MESSAGE\n";
      for my $i (0 .. $#messages) {
        print "SESSION-ENDING MESSAGE PART ", ($i + 1), " of ", scalar(@messages), "\n" if @messages > 1;
        my $body = defined $messages[$i]{prompt} && length $messages[$i]{prompt}
          ? $messages[$i]{prompt}
          : (defined $messages[$i]{text} ? $messages[$i]{text} : "");
        emit_body($body);
      }
      print "END SESSION-ENDING MESSAGE\n";
    } else {
      print "SESSION-ENDING MESSAGE: (none)\n";
    }
    print "\n";
    print "declared_items: $want\n";
    print "presented_items: $presented\n";
    print "malformed_items: $malformed\n";
    print "complete: $complete\n";
    print "lifecycle: $lifecycle\n";
    print "session_ended: ", (length $session_ended ? $session_ended : "(unset)"), "\n";
    print "annotation_count: ", scalar(@annotations), "\n";
    print "session_ending_message_count: ", scalar(@messages), "\n";
    print "\n";
    if (@annotations) {
      print "ANNOTATIONS\n";
      my $n = 0;
      for my $f (@annotations) {
        $n++;
        my $uid = defined $f->{uid} ? $f->{uid} : "";
        my $selector = defined $f->{selector} ? $f->{selector} : "";
        my $tag = defined $f->{tag} ? $f->{tag} : "";
        print "ANNOTATION $n of ", scalar(@annotations), "\n";
        print "element_uid: $uid\n";
        print "element_selector: $selector\n";
        print "tag: $tag\n";
        print "text:\n";
        my $elem = defined $f->{text} ? $f->{text} : "";
        my $comment = defined $f->{prompt} ? $f->{prompt} : "";
        my $body = length $elem ? $elem : $comment;
        emit_body($body);
        if ($tag ne "choice" && length $comment) {
          print "prompt:\n";
          emit_body($comment);
        }
      }
      print "END ANNOTATIONS\n";
    } else {
      print "ANNOTATIONS: (none)\n";
    }
    print "END LAVISH RESULT ($presented of $want)\n";
  ' "$file" "$lifecycle" "$session_ended"
}

case "${1-}" in
  retire-registered) shift; cmd_retire_registered "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  silent)    shift; cmd_silent "$@" ;;
  answers)   shift; cmd_answers "$@" ;;
  reconciles) shift; cmd_reconciles "$@" ;;
  read)      shift; cmd_read "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
