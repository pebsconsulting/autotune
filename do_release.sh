#!/bin/bash

echo You should run this and do a release BEFORE making changes to master

if ! git diff-index --quiet HEAD --; then
  echo You must have a clean repo with no changes or staged commits before updating the version
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo >&2 "Missing jq. Please install jq."; exit 1; }

old_version=$(jq '.version' package.json | tr -d '"')

if [ $# -ne 1 ]; then
  read -p "Current version is $old_version. Enter a new version: " version
else
  version=$1
fi

if [ "$old_version" = "$version" ]; then
  echo Already at version $version
  exit 1
fi

echo Updating version to $version

{ rm package.json && jq --arg version $version '.version |= $version' > package.json; } < package.json

read -p "Do you wish to commit the new version, tag and push? [y/N] " yn
if echo "$yn" | grep -iq "^y"; then
  git commit -am "bump to $version" && git tag v$version && git push && git push --tags
fi
