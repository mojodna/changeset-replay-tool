#!/usr/bin/env bash

commit=$1
osm_base_url=${OSM_BASE_URL:-http://localhost:3001}

if [[ "$commit" == "" ]]; then
  >&2 echo "Usage: $0 <commit>"
fi

set -euo pipefail

# create a new remote changeset
>&2 echo "===> Creating a new changeset"
git show -s --format=%B > changeset.xml
changeset_id=$(curl -sfX PUT -d @changeset.xml -H "Content-Type: application/xml" ${osm_base_url}/api/0.6/changeset/create)

>&2 echo "===> Generating OSMChange for ${changeset_id}"

# create an OSC from the current repo state
# prevent diff and rename detection unless files are 100% identical
# git diff -C100% -M100% --name-status @^ | sort | node ../generate-osc.js -c $changeset_id -m map.json > changeset.osc
git diff --no-renames --name-status @^ | sort | node ../generate-osc.js -c $changeset_id -m map.json > changeset.osc

>&2 echo "===> Uploading to changeset ${changeset_id}"
curl -sX POST -d @changeset.osc -H "Content-Type: application/xml" ${osm_base_url}/api/0.6/changeset/${changeset_id}/upload -o response >&2

file_type=$(file -b --mime-type response)

# check the response; if it was XML, it was successful
if [ "application/xml" != "$file_type" ]; then
  >&2 echo "Error:"
  >&2 cat response
  >&2 echo

  # TODO close the changeset
  # Here's your chance to fix the data, generate the changeset and continue

  exit 1
fi

cat response >&2

# stash the id remapping
cat response | node ../handle-diffresult.js -m map.json > .git/${commit}.json
# ensure that something exists
test -f .git/map.json || echo "{}" > .git/map.json
cat .git/map.json .git/${commit}.json | jq -s '.[0] * .[1]' > .git/map2.json
mv .git/map2.json .git/map.json

# close the changeset
>&2 echo "===> Closing changeset ${changeset_id}"
curl -sfX PUT ${osm_base_url}/api/0.6/changeset/${changeset_id}/close

echo "Changeset #${changeset_id}" > commit.message
echo >> commit.message
cat response >> commit.message

# renumber nds and members
>&2 echo "===> Renumbering"
node ../renumber.js -m .git/map.json

git add */

>&2 echo "===> Committing transformation"
git commit --allow-empty -F commit.message >> ../submit.log

git clean -f >> ../submit.log

# move the upstream tag now that it includes our data
git tag -f upstream $commit

# tag it with the upstream changeset id
git tag -f osm/${changeset_id}
