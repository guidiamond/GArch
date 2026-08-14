#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[]"
  exit 1
fi

source "$ENV_FILE"

if [[ -z "$TODOIST_API_TOKEN" ]]; then
  echo "[]"
  exit 1
fi

case "$1" in
  close)
    task_id="$2"
    if [[ -z "$task_id" ]]; then
      echo "Error: task_id required"
      exit 1
    fi
    curl -s -X POST \
      "https://api.todoist.com/api/v1/tasks/${task_id}/close" \
      -H "Authorization: Bearer $TODOIST_API_TOKEN" >/dev/null 2>&1
    # Refresh eww after closing
    eww update todoist-tasks="$(bash "$0" fetch)"
    ;;
  fetch|"")
    response=$(curl -s \
      "https://api.todoist.com/api/v1/tasks" \
      -H "Authorization: Bearer $TODOIST_API_TOKEN")
    echo "$response" | jq -c '[.results[] | {
      id: .id,
      content: .content,
      priority: .priority,
      due: (if .due then .due.date else null end)
    }] | sort_by(-.priority) | .[0:15]'
    ;;
  *)
    echo "Usage: todoist.sh [fetch|close <task_id>]"
    exit 1
    ;;
esac
