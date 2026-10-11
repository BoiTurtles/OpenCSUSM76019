#!/bin/bash
# cs446 midterm (opencsusm)
# usage: bash opencsusm.sh <stage>
#   1 quota + price   2 launch       3 install vllm   4 serve model
#   5 tunnel cmd      6 hello john   7 stop           8 delete everything
#   chat   talk to the model (tunnel has to be up)
#   fixip  fix the ssh rule if my ip changed

set -euo pipefail
export AWS_PAGER=""

REGION=us-east-1
export AWS_DEFAULT_REGION=$REGION

# lane: gpu
# my G quota got approved at 4 vcpus, which is exactly one g4dn.xlarge.
# vllm is built for gpus, and $0.526/hr is ~190 hrs on the $100
LANE=gpu
TYPE=g4dn.xlarge    # 4 vcpu, 16gb ram, 1x T4 (16gb)

# smallest model that passes the hello john test (~1gb)
MODEL=Qwen/Qwen2.5-0.5B-Instruct
PORT=8000           # never opened in the security group, only reached through the tunnel

KEYNAME=opencsusm-key
KEY=$HOME/.ssh/$KEYNAME.pem
SG=cs446-midterm-sg
TAG=cs446-midterm
DISK=100            # gb, gp3

# deep learning base ami, ubuntu 24.04 with the nvidia driver already on it
AMI_PARAM=/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-24.04/latest/ami-id

DIR=$(cd "$(dirname "$0")" && pwd)

die() { echo "error: $*" >&2; exit 1; }
show() { [ -z "$1" ] || echo "$1"; }

sshi() {
  local h=$1; shift
  ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      -o ServerAliveInterval=30 "ubuntu@$h" "$@"
}

# my instance(s), anything not terminated
inst() {
  aws ec2 describe-instances \
    --filters Name=tag:Project,Values=$TAG \
              Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

dns() {
  local id state
  id=$(inst | awk '{print $1}')
  [ -n "$id" ] || die "no instance, run stage 2"
  state=$(aws ec2 describe-instances --instance-ids $id \
          --query 'Reservations[0].Instances[0].State.Name' --output text)
  [ "$state" = running ] || die "$id is $state"
  aws ec2 describe-instances --instance-ids $id \
    --query 'Reservations[0].Instances[0].PublicDnsName' --output text
}

sgid() {
  aws ec2 describe-security-groups --filters Name=group-name,Values=$SG \
    --query 'SecurityGroups[0].GroupId' --output text
}

# wipe the inbound rules, then open only port 22 to my ip
lock_sg() {
  local sg=$1 ip perms
  ip=$(curl -s https://checkip.amazonaws.com)
  [ -n "$ip" ] || die "couldn't get my ip"
  perms=$(aws ec2 describe-security-groups --group-ids $sg \
          --query 'SecurityGroups[0].IpPermissions' --output json)
  if [ "$perms" != "[]" ]; then
    aws ec2 revoke-security-group-ingress --group-id $sg --ip-permissions "$perms" > /dev/null
  fi
  aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 22 \
    --cidr $ip/32 > /dev/null
  echo "port 22 open to $ip/32 only"
}

# on-demand linux price from the pricing api
price() {
  aws pricing get-products --service-code AmazonEC2 \
    --filters Type=TERM_MATCH,Field=instanceType,Value=$TYPE \
              Type=TERM_MATCH,Field=regionCode,Value=$REGION \
              Type=TERM_MATCH,Field=operatingSystem,Value=Linux \
              Type=TERM_MATCH,Field=tenancy,Value=Shared \
              Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
              Type=TERM_MATCH,Field=capacitystatus,Value=Used \
    --query 'PriceList[0]' --output text 2> /dev/null |
    tr -d ' \n' | sed 's/.*"OnDemand":{//' |
    grep -o '"USD":"[0-9.]*"' | head -1 | grep -o '[0-9][0-9.]*' || true
}

s1() {
  local p
  aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA \
    --query '{quota:Quota.QuotaName,value:Quota.Value}' --output table
  echo "(that's vcpus, g4dn.xlarge needs 4)"
  p=$(price)
  if [ -n "$p" ]; then
    awk -v p="$p" -v t=$TYPE 'BEGIN { printf "%s: $%.4f/hr, ~%d hrs on $100\n", t, p, 100/p }'
  else
    echo "couldn't get the live price (slides say \$0.526/hr)"
  fi
}

s2() {
  local sg ami root size id
  [ -z "$(inst)" ] || die "already have an instance up, run stage 8 first"

  if [ ! -f "$KEY" ]; then
    mkdir -p ~/.ssh
    aws ec2 create-key-pair --key-name $KEYNAME --query KeyMaterial --output text > "$KEY"
    chmod 400 "$KEY"
    echo "made key $KEY"
  fi

  sg=$(sgid)
  if [ "$sg" = None ]; then
    sg=$(aws ec2 create-security-group --group-name $SG \
         --description "cs446 midterm, ssh only" --query GroupId --output text)
  fi
  lock_sg $sg

  ami=$(aws ssm get-parameter --name $AMI_PARAM --query Parameter.Value --output text)
  root=$(aws ec2 describe-images --image-ids $ami --query 'Images[0].RootDeviceName' --output text)
  size=$(aws ec2 describe-images --image-ids $ami \
         --query "Images[0].BlockDeviceMappings[?DeviceName=='$root'].Ebs.VolumeSize | [0]" \
         --output text)
  # disk can't be smaller than the ami's
  [ "$size" -gt $DISK ] 2> /dev/null || size=$DISK

  echo "launching $TYPE ($ami), ${size}gb disk"
  id=$(aws ec2 run-instances --image-id $ami --instance-type $TYPE \
       --key-name $KEYNAME --security-group-ids $sg \
       --block-device-mappings "[{\"DeviceName\":\"$root\",\"Ebs\":{\"VolumeSize\":$size,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
       --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG},{Key=Project,Value=$TAG}]" \
                            "ResourceType=volume,Tags=[{Key=Project,Value=$TAG}]" \
       --query 'Instances[0].InstanceId' --output text)
  echo "$id launched, billing starts now"
  aws ec2 wait instance-running --instance-ids $id
  echo "ssh -i $KEY ubuntu@$(dns)"
}

s3() {
  local h i
  h=$(dns)
  echo "waiting for ssh..."
  for i in $(seq 30); do
    sshi $h true < /dev/null > /dev/null 2>&1 && break
    [ $i = 30 ] && die "can't ssh in (ip changed? try fixip)"
    sleep 10
  done

  echo "installing vllm on $h"
  sshi $h bash -s << 'EOF'
set -e
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
export PATH=$HOME/.local/bin:$PATH
command -v uv > /dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
[ -d ~/vllm-env ] || uv venv --python 3.12 --seed ~/vllm-env
uv pip install --python ~/vllm-env/bin/python vllm --torch-backend=auto
~/vllm-env/bin/python -c "import vllm, torch; print('vllm', vllm.__version__, 'torch', torch.__version__, 'cuda:', torch.cuda.is_available())"
EOF
}

# --host 127.0.0.1 so vllm only listens on the box itself
# --dtype half since the T4 can't do bf16
s4() {
  local h
  h=$(dns)
  sshi $h "MODEL=$MODEL PORT=$PORT bash -s" << 'EOF'
set -e
if ! pgrep -f "vllm-env/bin/vllm serve" > /dev/null; then
  nohup ~/vllm-env/bin/vllm serve $MODEL --host 127.0.0.1 --port $PORT \
    --dtype half --max-model-len 4096 --enforce-eager > ~/vllm.log 2>&1 < /dev/null &
fi
echo "waiting for vllm..."
for i in $(seq 90); do
  if grep -q "startup complete" ~/vllm.log 2> /dev/null; then
    grep -m1 "startup complete" ~/vllm.log
    exit 0
  fi
  pgrep -f "vllm-env/bin/vllm serve" > /dev/null || { tail -40 ~/vllm.log; exit 1; }
  sleep 10
done
tail -40 ~/vllm.log
exit 1
EOF
}

s5() {
  local h
  h=$(dns)
  echo "run this in a second terminal and leave it open:"
  echo "  ssh -i $KEY -N -L $PORT:localhost:$PORT ubuntu@$h"
}

# localhost here is my laptop, the request goes through the tunnel on port 22
s6() {
  local out=$DIR/stage6_reply.txt
  curl -sS -m 60 localhost:$PORT/v1/chat/completions -H 'Content-Type: application/json' \
    -d "{\"model\": \"$MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"I am John\"}], \"max_tokens\": 20, \"temperature\": 0}" \
    > "$out" || die "nothing on localhost:$PORT, is the tunnel up?"
  cat "$out"; echo
  if grep -q John "$out"; then echo PASS; else echo "no John in the reply?"; fi
}

s7() {
  local id
  id=$(inst | awk '{print $1}')
  [ -n "$id" ] || die "no instance"
  aws ec2 stop-instances --instance-ids $id > /dev/null
  aws ec2 wait instance-stopped --instance-ids $id
  echo "stopped $id (disk still bills until stage 8)"
}

# delete everything, then list whatever's left. no output = all gone
s8() {
  local ids sg i
  ids=$(inst)
  if [ -n "$ids" ]; then
    aws ec2 terminate-instances --instance-ids $ids > /dev/null
    aws ec2 wait instance-terminated --instance-ids $ids
  fi

  sg=$(sgid)
  if [ "$sg" != None ]; then
    # the sg can't be deleted until the old network interface lets go of it
    for i in $(seq 12); do
      aws ec2 delete-security-group --group-id $sg > /dev/null 2>&1 && break
      sleep 10
    done
  fi

  show "$(aws ec2 describe-instances \
          --filters Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
          --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' --output text)"
  show "$(aws ec2 describe-volumes --query 'Volumes[].[VolumeId,Size,State]' --output text)"
  show "$(aws ec2 describe-security-groups --filters Name=group-name,Values=$SG \
          --query 'SecurityGroups[].GroupId' --output text)"
}

# chat with the model through the tunnel. sends the whole convo each time
# so it remembers what i said earlier
chat() {
  local url=localhost:$PORT/v1/chat/completions msgs text resp reply
  command -v jq > /dev/null || die "need jq (brew install jq)"
  curl -s -m 5 localhost:$PORT/v1/models > /dev/null || die "nothing on localhost:$PORT, is the tunnel up?"

  msgs='[{"role":"system","content":"You are a helpful assistant. Keep answers short."}]'
  echo "chatting with $MODEL, /exit to quit"
  while IFS= read -r -p "you: " text; do
    [ "$text" = /exit ] && break
    [ -z "${text// /}" ] && continue

    msgs=$(jq -c --arg t "$text" '. + [{role: "user", content: $t}]' <<< "$msgs")
    resp=$(curl -sS -m 120 $url -H 'Content-Type: application/json' \
           -d "$(jq -c --arg m $MODEL '{model: $m, messages: ., max_tokens: 256}' <<< "$msgs")") || resp=
    reply=$(jq -r '.choices[0].message.content // empty' <<< "$resp" 2> /dev/null || true)

    if [ -z "$reply" ]; then
      echo "(no reply) $resp"
      msgs=$(jq -c 'del(.[-1])' <<< "$msgs")
      continue
    fi
    printf 'qwen: %s\n\n' "$reply"
    msgs=$(jq -c --arg r "$reply" '. + [{role: "assistant", content: $r}]' <<< "$msgs")
  done
}

case ${1:-} in
  1) s1 ;;
  2) s2 ;;
  3) s3 ;;
  4) s4 ;;
  5) s5 ;;
  6) s6 ;;
  7) s7 ;;
  8) s8 ;;
  chat) chat ;;
  fixip) lock_sg "$(sgid)" ;;
  *) sed -n 3,7p "$0"; exit 1 ;;
esac
exit 0

# ---- results ----
# stage 6 reply:
# {"id":"chatcmpl-be8315248a5a684b","object":"chat.completion","created":1791690292,"model":"Qwen/Qwen2.5-0.5B-Instruct","choices":[{"index":0,"message":{"role":"assistant","content":"Hello John! It's nice to meet you. As an AI language model, I don't have","refusal":null,"annotations":null,"audio":null,"function_call":null,"reasoning":null},"logprobs":null,"finish_reason":"length","stop_reason":null,"token_ids":null,"routed_experts":null}],"service_tier":null,"system_fingerprint":"vllm-0.31.0-32ff4812","usage":{"prompt_tokens":32,"total_tokens":52,"completion_tokens":20,"prompt_tokens_details":null,"completion_tokens_details":null},"prompt_logprobs":null,"prompt_token_ids":null,"prompt_text":null,"kv_transfer_params":null,"ec_transfer_params":null,"metrics":null}
# stage 8 output: (empty)
