#!/usr/bin/env bash
# Message telemetry port. Append-only daily JSONL under
# state/fm-message/telemetry/YYYY-MM-DD.jsonl; schema=fm-message-telemetry.v1.
# Retain seven UTC dates (today plus six): expire regular daily files on append.
# Stats read <=512 KiB each from today/yesterday, reduce only the last 24 hours,
# and expose complete=false for bounded tails or unfinished edges; bytesRead
# counts source bytes. Retained files remain append-only, with no daily size cap.
# One request id joins intake, decisions, adapter results and terminal counters.
# No text, environment, argv or captured stderr is logged; only bounded ids,
# sizes, static reason codes, timings and public task execution dimensions.
# Model tokens/cost remain null: this module does not call a model provider.
# Logging failures warn without changing an already-delivered message outcome.
# Usage: fm_message_log <event> <outcome> <static-reason>
#        fm_message_stats <state-dir>  (rolling last 24 hours, JSON)
# The calling send's locals supply request context; no background process is added.

# shellcheck source=bin/fm-timing-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-timing-lib.sh"
_FM_MESSAGE_PRUNED_FILE=''

fm_message_telemetry_id() {  # <identifier>, never arbitrary rejected input
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  [ "${#1}" -le 128 ] || return 0
  printf '%s' "$1"
}

fm_message_telemetry_dimension() {  # <model/harness/effort>
  case "$1" in *[!A-Za-z0-9._:@/+-]*) return 0 ;; esac
  [ "${#1}" -le 160 ] || return 0
  printf '%s' "$1"
}

fm_message_log() {
  local event=$1 outcome=$2 reason=$3 dir file now row elapsed step_elapsed state thread_id evidence lock stamp epoch
  state="$FM_HOME/state"
  dir="$state/fm-message/telemetry"
  if [ -L "$state" ] || [ -L "$state/fm-message" ] || [ -L "$dir" ]; then
    echo 'warning: message telemetry path is symlinked; logging refused' >&2; return 0
  fi
  stamp=$(date -u '+%s %Y-%m-%dT%H:%M:%SZ') || { echo 'warning: message telemetry clock unavailable' >&2; return 0; }
  epoch=${stamp%% *}; stamp=${stamp#* }
  file="$dir/${stamp%%T*}.jsonl"
  if [ -L "$file" ] || ! mkdir -p "$dir"; then
    echo 'warning: message telemetry is unavailable' >&2; return 0
  fi
  now=$(fm_timing_now_ms); elapsed=$((now-${started_ms:-now})); step_elapsed=$((now-${step_ms:-now}))
  [ "$elapsed" -ge 0 ] || elapsed=0
  [ "$step_elapsed" -ge 0 ] || step_elapsed=0
  thread_id=$(fm_message_telemetry_id "${thread:-}")
  evidence=''
  [ -z "${ledger:-}" ] || evidence="data/threads/$thread_id.md"
  row=$(jq -cn --arg ts "$stamp" \
    --arg event "$event" --arg request "${request_id:-}" --arg message "${id:-}" \
    --arg thread "$thread_id" --arg actor "$(fm_message_telemetry_id "${sender:-}")" --arg outcome "$outcome" \
    --arg phase "${phase:-intake}" --arg reason "$reason" --arg evidence "$evidence" \
    --arg model "$(fm_message_telemetry_dimension "${sender_model:-}")" \
    --arg harness "$(fm_message_telemetry_dimension "${sender_harness:-}")" \
    --arg effort "$(fm_message_telemetry_dimension "${sender_effort:-}")" \
    --arg recipients "${recipients:-}" --arg target "$(fm_message_telemetry_id "${meta:-}")" \
    --argjson textBytes "${text_size:-0}" --argjson recipientCount "${recipient_count:-0}" \
    --argjson elapsed "$elapsed" --argjson stepElapsed "$step_elapsed" \
    --argjson validated "${validated_count:-0}" --argjson delivered "${delivered_count:-0}" \
    --argjson failed "${failed_count:-0}" --argjson retries "${retry_count:-0}" '
      {schema:"fm-message-telemetry.v1",ts:$ts,module:"fm-message",event:$event,
       requestId:$request,messageId:($message|if .=="" then null else . end),
       threadId:($thread|if .=="" then null else . end),actor:($actor|if .=="" then null else . end),
       inputs:{bytes:$textBytes,recipientCount:$recipientCount,
         ids:($recipients|split("\n")|map(select(length>0))),targetId:($target|if .=="" then null else . end)},
       decision:$phase,reasons:[$reason],stepsMs:{total:$elapsed,($phase):$stepElapsed},
       model:($model|if .=="" then null else . end),harness:($harness|if .=="" then null else . end),
       effort:($effort|if .=="" then null else . end),tokens:null,cost:null,
       outcome:($outcome|if .=="" then null else . end),
       evidencePath:($evidence|if .=="" then null else . end),
       counters:{validated:$validated,delivered:$delivered,failed:$failed,retries:$retries}}
    ') || { echo 'warning: message telemetry encoding failed' >&2; return 0; }
  lock="$dir/.append.lock"
  if fm_task_inbox_lock_acquire "$lock"; then
    if [ -L "$state" ] || [ -L "$state/fm-message" ] || [ -L "$dir" ] || [ -L "$file" ]; then
      echo 'warning: message telemetry path changed; logging refused' >&2
    else
      if [ "$_FM_MESSAGE_PRUNED_FILE" != "$file" ]; then
        if perl -MPOSIX=strftime -e '
          my ($dir, $now) = @ARGV;
          my $cutoff = strftime("%Y-%m-%d", gmtime($now - 6 * 86400));
          opendir(my $dh, $dir) or die "telemetry directory unavailable: $!\n";
          while (my $name = readdir($dh)) {
            next unless $name =~ /\A(\d{4}-\d{2}-\d{2})\.jsonl\z/ && $1 lt $cutoff;
            my $path = "$dir/$name";
            next if -l $path || !-f $path;
            unlink($path) or die "telemetry expiry failed: $!\n";
          }
          closedir($dh);
        ' "$dir" "$epoch"; then _FM_MESSAGE_PRUNED_FILE=$file
        else echo 'warning: message telemetry expiry incomplete' >&2
        fi
      fi
      printf '%s\n' "$row" >> "$file" || echo 'warning: message telemetry append failed' >&2
    fi
    fm_lock_release "$lock"
  else
    echo 'warning: message telemetry append lock unavailable' >&2
  fi
  return 0
}

fm_message_step() {  # <step>
  phase=$1
  step_ms=$(fm_timing_now_ms)
  fm_message_log step '' entered
}

fm_message_stats() (  # <state-dir>
  set -o pipefail
  local dir="$1/fm-message/telemetry"
  [ ! -L "$1" ] && [ ! -L "$1/fm-message" ] && [ ! -L "$dir" ] || return 1
  # Two fixed paths, bounded tails, then a streaming reduction, never archive slurping.
  perl -MFcntl=O_RDONLY,O_NONBLOCK,O_NOFOLLOW,SEEK_SET,S_ISREG -MErrno=ENOENT,EINTR -MPOSIX=strftime -MJSON::PP=encode_json -e '
    my ($dir) = @ARGV;
    my ($now, $bytes, $complete) = (time, 0, 1);
    my @chunks;
    for my $age (86400, 0) {
      my $file = "$dir/" . strftime("%Y-%m-%d", gmtime($now - $age)) . ".jsonl";
      sysopen(my $fh, $file, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) or do { next if $! == ENOENT; die "telemetry open refused: $!\n"; };
      my @stat = stat($fh);
      @stat && S_ISREG($stat[2]) or die "telemetry is not a regular file\n";
      my $start = $stat[7] > 524288 ? $stat[7] - 524288 : 0;
      defined(sysseek($fh, $start, SEEK_SET)) or die "telemetry seek failed: $!\n";
      my $wanted = $stat[7] - $start;
      my $data = "";
      while (length($data) < $wanted) {
        my $count = sysread($fh, my $chunk, $wanted - length($data));
        if (!defined($count)) { next if $! == EINTR; die "telemetry read failed: $!\n"; }
        last unless $count;
        $data .= $chunk;
      }
      close($fh) or die "telemetry close failed: $!\n";
      $bytes += length($data);
      $complete = 0 if length($data) < $wanted;
      if ($start) { $complete = 0; $data =~ s/\A[^\n]*(?:\n|\z)//; }
      if (length($data) && substr($data, -1) ne "\n") { $complete = 0; $data =~ s/[^\n]*\z//; }
      push @chunks, $data;
    }
    print encode_json({now => $now, bytes => $bytes, complete => $complete ? JSON::PP::true : JSON::PP::false}), "\n", @chunks;
  ' "$dir" | jq -ne '
    input as $window
    | reduce inputs as $row (
      {schema:"fm-message-stats.v1",hours:24,complete:$window.complete,bytesRead:$window.bytes,
       events:0,requests:0,accepted:0,rejected:0,errors:0,delivered:0};
      if $row.schema!="fm-message-telemetry.v1" then error("unknown telemetry schema")
      else ($row.ts|fromdateiso8601) as $ts
      | if $ts<($window.now-86400) or $ts>$window.now then .
        else .events+=1
        | if $row.event=="finished" then .requests+=1
          | .accepted+=(if $row.outcome=="accepted" then 1 else 0 end)
          | .rejected+=(if $row.outcome=="rejected" then 1 else 0 end)
          | .errors+=(if $row.outcome=="error" then 1 else 0 end)
          | .delivered+=($row.counters.delivered//0)
          else . end
        end
      end)
  '
)
