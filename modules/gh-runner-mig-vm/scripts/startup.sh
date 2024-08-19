#!/bin/bash
# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#install jq
apt-get update
apt-get -y install jq

setup_additional_packages () {
    apt-get -y install unzip
    {
        echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        echo "github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg="
        echo "github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk="
    } >> /root/.ssh/known_hosts
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash
    # shellcheck disable=SC1090
    {
        echo 'export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"'
        # shellcheck disable=SC1091
        echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm'
    } >> /etc/skel/.bashrc
    source /etc/skel/.bashrc
    nvm install --lts

}

generate_gha_jwt () {
  ####################
  # Generate JWT token
  # Doc: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app
  ####################
  
  client_id="$GHA_CLIENT_ID" # Client ID as first argument
  
  pem=$(echo -n "$GHA_PRIVATE_KEY" | base64 --decode) # file path of the private key as second argument
  
  now=$(date +%s)
  iat=$((now - 60)) # Issues 60 seconds in the past
  exp=$((now + 600)) # Expires 10 minutes in the future
  
  #b64enc() { tr -d '\n' | tr -d '\r' | base64 | tr '+/' '-_' | tr -d '='; }
  b64enc() { openssl base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'; }
  
  header_json='{
      "typ":"JWT",
      "alg":"RS256"
  }'
  # Header encode
  header=$( echo -n "${header_json}" | b64enc )
  
  payload_json='{
      "iat":'"${iat}"',
      "exp":'"${exp}"',
      "iss":"'"${client_id}"'"
  }'
  # Payload encode
  payload=$( echo -n "${payload_json}" | b64enc )
  
  # Signature
  header_payload="${header}"."${payload}"
  signature=$(
      openssl dgst -sha256 -sign <(echo -n "${pem}") \
      <(echo -n "${header_payload}") | b64enc
  )
  
  # Create JWT
  JWT="${header_payload}"."${signature}"
  
  #printf "%s\n" "$JWT"
}

secretUri=$(curl -sS "http://metadata.google.internal/computeMetadata/v1/instance/attributes/secret-id" -H "Metadata-Flavor: Google")
#secrets URI is of the form projects/$PROJECT_NUMBER/secrets/$SECRET_NAME/versions/$SECRET_VERSION
#split into array based on `/` delimeter
IFS="/" read -r -a secretsConfig <<<"$secretUri"
#get SECRET_NAME and SECRET_VERSION
SECRET_NAME=${secretsConfig[3]}
SECRET_VERSION=${secretsConfig[5]}
#access secret from secretsmanager
secrets=$(gcloud secrets versions access "$SECRET_VERSION" --secret="$SECRET_NAME")
#set secrets as env vars
# shellcheck disable=SC2046
# we want to use wordsplitting
export $(echo "$secrets" | jq -r "to_entries|map(\"\(.key)=\(.value|tostring)\")|.[]")
#github runner version
GH_RUNNER_VERSION=${RUNNER_VERSION:-2.283.3}

#only execute when client_id and private_key are not empty
#use as check to see if we want to use github app for authentication
#because we are overwriting the GITHUB_TOKEN variable
if [[ -n $GHA_CLIENT_ID ]] && [[ -n $GHA_PRIVATE_KEY ]]; then
    generate_gha_jwt

    #Get access token
    #Docs: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app
    GITHUB_TOKEN=$(curl --request POST \
    --url "https://api.github.com/app/installations/${GHA_INSTALLATION_ID}/access_tokens" \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer ${JWT}" \
    --header "X-GitHub-Api-Version: 2022-11-28" | jq -r .token)
fi

#get actions binary
curl -o actions.tar.gz --location "https://github.com/actions/runner/releases/download/v${GH_RUNNER_VERSION}/actions-runner-linux-x64-${GH_RUNNER_VERSION}.tar.gz"
mkdir /runner
mkdir /runner-tmp
tar -zxf actions.tar.gz --directory /runner
rm -f actions.tar.gz
/runner/bin/installdependencies.sh
#get actions token
# shellcheck disable=SC2034
# ACTIONS_RUNNER_INPUT_NAME is used by config.sh
ACTIONS_RUNNER_INPUT_NAME=$HOSTNAME
if [[ -z $REPO_NAME ]]; then
    # Add action runner for an organisation
    POST_URL="https://api.github.com/orgs/${REPO_OWNER}/actions/runners/registration-token"
    GH_URL="https://github.com/${REPO_OWNER}"
else
    # Add action runner for a repo
    POST_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/actions/runners/registration-token"
    GH_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
fi

# Register runner
ACTIONS_RUNNER_INPUT_TOKEN="$(curl -sS --request POST --url "$POST_URL" --header "authorization: Bearer ${GITHUB_TOKEN}" --header 'content-type: application/json' | jq -r .token)"
#configure runner
RUNNER_ALLOW_RUNASROOT=1 /runner/config.sh --unattended --replace --work "/runner-tmp" --url "$GH_URL" --token "$ACTIONS_RUNNER_INPUT_TOKEN" --labels "$LABELS" --runnergroup "${RUNNER_GROUP}"

#install and start runner service
cd /runner || exit
./svc.sh install
./svc.sh start

#setup additional packages
setup_additional_packages