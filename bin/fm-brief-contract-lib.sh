#!/usr/bin/env bash

fm_brief_crew_branch() {  # <brief-path>
  sed -n 's/^Crew branch: branch=//p' "$1" | tail -n 1
}
