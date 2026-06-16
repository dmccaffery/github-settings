#!/usr/bin/env sh
set -eu

# org-config.sh — export/import a GitHub organisation's rulesets and general
# settings, the org-level companion to repo-config.sh.
#
#   ./org-config.sh export <org> [dir]   # dump config  -> dir (default: ./org-config)
#   ./org-config.sh import <org> [dir]   # apply config <- dir
#
# What's covered:
#   - Organisation-level rulesets only (full definitions: conditions, rules,
#     bypass_actors); rulesets inherited from an enterprise are ignored in both
#     directions. Org rulesets share the repo-ruleset shape but their conditions
#     also target which repositories they apply to (repository_name /
#     repository_property), captured as part of conditions.
#   - General org settings, grouped as:
#       member-privileges  default_repository_permission,
#                          members_can_create_repositories and the
#                          public/private/internal/pages variants,
#                          members_can_fork_private_repositories
#       new-repo defaults  dependabot / dependency-graph / secret-scanning
#                          toggles applied to repositories created in the org
#       commits            web_commit_signoff_required
#
# Deliberately excluded: identity (name, description, billing_email, company,
# email, location, blog), plan/seat data, and anything server-managed.
#
# Mirror semantics: both directions sync rather than merge.
#   - export wipes <dir>/rulesets first, so it reflects exactly what's live.
#   - import makes the org's rulesets match <dir>/rulesets: update/create the
#     ones with a file, delete any ruleset that has no matching file. A missing
#     rulesets dir is left untouched; an empty one means "remove them all".
#
# Env:
#   STRIP_BYPASS=1   drop ruleset bypass_actors on export — use when the bypass
#                    actors (teams, apps, custom roles) won't exist in the target.
#
# Requires: gh (authenticated, org owner), jq.
# Note: reading/writing org settings and rulesets requires organisation owner;
#       switch accounts with `gh auth switch` if the active one lacks access.

SETTINGS_FILTER='{
  default_repository_permission,
  members_can_create_repositories,
  members_can_create_public_repositories,
  members_can_create_private_repositories,
  members_can_create_internal_repositories,
  members_can_create_pages,
  members_can_create_public_pages,
  members_can_create_private_pages,
  members_can_fork_private_repositories,
  web_commit_signoff_required,
  dependabot_alerts_enabled_for_new_repositories,
  dependabot_security_updates_enabled_for_new_repositories,
  dependency_graph_enabled_for_new_repositories,
  secret_scanning_enabled_for_new_repositories,
  secret_scanning_push_protection_enabled_for_new_repositories,
}'

usage() {
  echo "usage: $0 export <org> [dir]" >&2
  echo "       $0 import <org> [dir]" >&2
  exit 2
}

cmd="${1:-}"
org="${2:-}"
dir="${3:-org-config}"
[ -n "$cmd" ] && [ -n "$org" ] || usage

gh=/opt/homebrew/bin/gh

export_config() {
  mkdir -p "$dir/rulesets"

  # General settings (member-privileges / new-repo defaults / commits). Drop
  # nulls so plan-gated fields absent on this org aren't PATCHed back as null.
  ${gh} api "orgs/$org" | jq "$SETTINGS_FILTER | with_entries(select(.value != null))" >"$dir/settings.json"
  echo "exported settings  -> $dir/settings.json"

  # Mirror reality: drop previously-exported rulesets so any removed upstream
  # don't linger here as stale files.
  rm -f "$dir"/rulesets/*.json

  # Rulesets: fetch each full definition, reduce to the create payload, and
  # name the file after the (sanitized) ruleset name for readability.
  strip='.'
  [ -n "${STRIP_BYPASS:-}" ] && strip='del(.bypass_actors)'
  ${gh} api --paginate "orgs/$org/rulesets?includes_parents=false" --jq '.[].id' | while read -r id; do
    [ -n "$id" ] || continue
    full=$(${gh} api "orgs/$org/rulesets/$id")
    name=$(printf '%s' "$full" | jq -r '.name')
    safe=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-')
    printf '%s' "$full" |
      jq "{name, target, enforcement, bypass_actors, conditions, rules}
            | with_entries(select(.value != null)) | $strip" \
        >"$dir/rulesets/$safe.json"
    echo "exported ruleset   -> $dir/rulesets/$safe.json"
  done
}

import_config() {
  if [ -f "$dir/settings.json" ]; then
    ${gh} api -X PATCH "orgs/$org" --input "$dir/settings.json" >/dev/null
    echo "applied settings   <- $dir/settings.json"
  else
    echo "no $dir/settings.json; skipping settings" >&2
  fi

  # Rulesets: mirror the files onto the org. A missing rulesets dir is left
  # alone; an empty dir is a real instruction to remove every ruleset.
  if [ -d "$dir/rulesets" ]; then
    tab=$(printf '\t')

    # Snapshot the org's current rulesets as "<id>\t<name>" lines.
    remote=$(${gh} api --paginate "orgs/$org/rulesets?includes_parents=false" --jq '.[] | [.id, .name] | @tsv')

    # The set of names we hold a file for (one per line).
    names=$(
      for f in "$dir"/rulesets/*.json; do
        [ -e "$f" ] || continue
        jq -r '.name' "$f"
      done
    )

    # Upsert: PUT when a ruleset of that name already exists, POST when it's new.
    # A failure is reported but does not abort the rest (gh prints to stderr).
    for f in "$dir"/rulesets/*.json; do
      [ -e "$f" ] || continue
      name=$(jq -r '.name' "$f")
      id=$(printf '%s\n' "$remote" | awk -F"$tab" -v n="$name" '$2 == n {print $1; exit}')
      if [ -n "$id" ]; then
        if ${gh} api -X PUT "orgs/$org/rulesets/$id" --input "$f" >/dev/null; then
          echo "updated ruleset    <- $name"
        else
          echo "FAILED ruleset     <- $name (see error above)" >&2
        fi
      elif ${gh} api -X POST "orgs/$org/rulesets" --input "$f" >/dev/null; then
        echo "created ruleset    <- $name"
      else
        echo "FAILED ruleset     <- $name (see error above)" >&2
      fi
    done

    # Delete: every remote ruleset without a matching file.
    printf '%s\n' "$remote" | while IFS="$tab" read -r id name; do
      [ -n "$id" ] || continue
      if printf '%s\n' "$names" | grep -Fxq -- "$name"; then
        continue
      fi
      if ${gh} api -X DELETE "orgs/$org/rulesets/$id" >/dev/null; then
        echo "deleted ruleset    -> $name (no local file)"
      else
        echo "FAILED delete      -> $name (see error above)" >&2
      fi
    done
  fi
}

case "$cmd" in
export) export_config ;;
import) import_config ;;
*) usage ;;
esac
