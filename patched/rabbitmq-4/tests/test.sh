#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
previous=docker.io/library/rabbitmq@sha256:a36989b2306803d31a0936d376c937e5bae5018e71a238ff457ee4144191109d
previous_repository=${previous%@*}

fail() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["docker-entrypoint.sh"]' ] || fail "unexpected entrypoint"
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["rabbitmq-server"]' ] || fail "unexpected command"
[ -z "$(docker image inspect --format '{{.Config.User}}' "$image")" ] || fail "image must start as root"
[ -z "$(docker image inspect --format '{{.Config.StopSignal}}' "$image")" ] || fail "image overrides StopSignal"
[ "$(docker image inspect --format '{{json .Config.Volumes}}' "$image")" = '{"/var/lib/rabbitmq":{}}' ] || fail "unexpected volumes"
exposed_ports=$(docker image inspect --format '{{range $port, $_ := .Config.ExposedPorts}}{{println $port}}{{end}}' "$image")
port_count=$(printf '%s\n' "$exposed_ports" | grep -c .)
[ "$port_count" -eq 6 ] || fail "unexpected exposed port count"
for expected_port in 4369 5671 5672 15691 15692 25672; do
  printf '%s\n' "$exposed_ports" | grep -qx "$expected_port/tcp" || fail "missing exposed port $expected_port"
done
! printf '%s\n' "$exposed_ports" | grep -qx '15672/tcp' || fail "management port must not be exposed"

env=$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image")
printf '%s\n' "$env" | grep -qx 'RABBITMQ_DATA_DIR=/var/lib/rabbitmq' || fail "missing RABBITMQ_DATA_DIR"
image_rabbitmq_version=$(printf '%s\n' "$env" | sed -n 's/^RABBITMQ_VERSION=//p')
case $image_rabbitmq_version in 4.3.*) ;; *) fail "unexpected RABBITMQ_VERSION $image_rabbitmq_version" ;; esac
printf '%s\n' "$env" | grep -qx 'HOME=/var/lib/rabbitmq' || fail "missing HOME"
docker run --rm --entrypoint sh "$image" -c '
  test "$(id -u rabbitmq)" = 999
  test "$(id -g rabbitmq)" = 999
' || fail "rabbitmq user must be 999:999"

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac

arch=$(docker image inspect --format '{{.Architecture}}' "$image")
case $arch in amd64 | arm64) ;; *) fail "unsupported candidate architecture $arch" ;; esac
container=verity-rabbitmq-$$
hostname=verity-rabbitmq-$$
queue=verity-quorum-$$
volume=verity-rabbitmq-data-$$
upgrade_image=local/verity-rabbitmq-upgrade-$$:$arch
upgrade_payload=verity-rabbitmq-upgrade-payload
restart_payload=verity-rabbitmq-restart-payload

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || :
  docker volume rm -f "$volume" >/dev/null 2>&1 || :
  docker image rm "$upgrade_image" >/dev/null 2>&1 || :
}
trap cleanup 0 1 2 3 15

version_at_least() {
  actual=$1
  required=$2
  while :; do
    actual_part=${actual%%.*}
    required_part=${required%%.*}
    [ "$actual" = "$actual_part" ] && actual= || actual=${actual#*.}
    [ "$required" = "$required_part" ] && required= || required=${required#*.}
    actual_part=${actual_part:-0}
    required_part=${required_part:-0}
    [ "$actual_part" -gt "$required_part" ] && return 0
    [ "$actual_part" -lt "$required_part" ] && return 1
    [ -n "$actual$required" ] || return 0
  done
}

wait_for_rabbitmq() {
  attempts=0
  while ! docker exec --user 999:999 "$container" rabbitmq-diagnostics -q ping >/dev/null 2>&1 \
    || ! docker exec --user 999:999 "$container" rabbitmq-diagnostics -q listeners 2>/dev/null | grep -q 'port: 5672,'; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
      docker logs "$container" >&2 || :
      fail "RabbitMQ did not become ready within 60 seconds"
    fi
    sleep 1
  done
}

assert_runtime_state() {
  docker exec "$container" sh -c '
    test "$(awk "/^Uid:/ {print \$2}" /proc/1/status)" = 999
    test "$(awk "/^Gid:/ {print \$2}" /proc/1/status)" = 999
    test "$(stat -c %a /var/lib/rabbitmq/.erlang.cookie)" = 400
    test "$(stat -c %u:%g /var/lib/rabbitmq/.erlang.cookie)" = 999:999
    test "$(stat -c %u:%g /var/lib/rabbitmq/ownership-repair)" = 999:999
    grep -q rabbitmq_prometheus /etc/rabbitmq/enabled_plugins
    ! grep -q rabbitmq_management /etc/rabbitmq/enabled_plugins
  ' || fail "runtime ownership or plugin contract failed"
  node=$(docker exec "$container" rabbitmqctl eval 'io:format("~s", [atom_to_list(node())]).')
  node=${node%ok}
  [ "$node" = "rabbit@$hostname" ] || fail "unexpected node identity $node"
}

previous_index=$(timeout 180 docker buildx imagetools inspect --raw "$previous") || \
  fail "cannot inspect previous image index"
previous_children=$(printf '%s\n' "$previous_index" | jq -r --arg arch "$arch" '
  .manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest
') || fail "cannot resolve previous image child digest"
previous_count=$(printf '%s\n' "$previous_children" | grep -c . || :)
case $previous_count in
  0) fail "no linux/$arch child digest in previous image index" ;;
  1) ;;
  *) fail "multiple linux/$arch child digests in previous image index" ;;
esac
previous_child=$previous_children
printf '%s\n' "$previous_child" | grep -Eq '^sha256:[0-9a-f]{64}$' || \
  fail "invalid previous image child digest $previous_child"
previous_image=${previous_repository}@${previous_child}
timeout 180 docker pull --platform "linux/$arch" "$previous_image"
docker tag "$previous_image" "$upgrade_image"
[ "$(docker image inspect --format '{{.Architecture}}' "$upgrade_image")" = "$arch" ] || \
  fail "previous image architecture does not match candidate $arch"
docker volume create "$volume" >/dev/null
docker run --rm --user 0:0 --entrypoint sh -v "$volume:/var/lib/rabbitmq" "$upgrade_image" \
  -c ': > /var/lib/rabbitmq/ownership-repair; chown 0:999 /var/lib/rabbitmq/ownership-repair'
docker run -d --name "$container" --hostname "$hostname" -v "$volume:/var/lib/rabbitmq" "$upgrade_image" >/dev/null
wait_for_rabbitmq

install_quorum_client() {
docker exec -i "$container" sh <<'EOF'
cat > /tmp/quorum.escript <<'ESCRIPT'
#!/usr/bin/env escript
-include_lib("amqp_client/include/amqp_client.hrl").

main(["publish", QueueText, PayloadText]) ->
    Queue = list_to_binary(QueueText),
    Payload = list_to_binary(PayloadText),
    {Connection, Channel} = channel(),
    #'queue.declare_ok'{message_count = 0} = amqp_channel:call(Channel,
        #'queue.declare'{queue = Queue, durable = true,
                         arguments = [{<<"x-queue-type">>, longstr, <<"quorum">>}]}),
    #'confirm.select_ok'{} = amqp_channel:call(Channel, #'confirm.select'{}),
    amqp_channel:cast(Channel, #'basic.publish'{routing_key = Queue},
        #amqp_msg{props = #'P_basic'{delivery_mode = 2}, payload = Payload}),
    true = amqp_channel:wait_for_confirms(Channel),
    #'queue.declare_ok'{message_count = 1} = amqp_channel:call(Channel,
        #'queue.declare'{queue = Queue, passive = true}),
    close(Connection, Channel);
main(["consume", QueueText, PayloadText]) ->
    Queue = list_to_binary(QueueText),
    Payload = list_to_binary(PayloadText),
    {Connection, Channel} = channel(),
    {#'basic.get_ok'{delivery_tag = Tag}, #amqp_msg{payload = Payload}} =
        amqp_channel:call(Channel, #'basic.get'{queue = Queue}),
    amqp_channel:cast(Channel, #'basic.ack'{delivery_tag = Tag}),
    #'queue.declare_ok'{message_count = 0} = amqp_channel:call(Channel,
        #'queue.declare'{queue = Queue, passive = true}),
    close(Connection, Channel);
main(["verify", QueueText, ExpectedText]) ->
    Queue = list_to_binary(QueueText),
    Expected = list_to_integer(ExpectedText),
    {Connection, Channel} = channel(),
    #'queue.declare_ok'{message_count = Expected} = amqp_channel:call(Channel,
        #'queue.declare'{queue = Queue, durable = true,
                         arguments = [{<<"x-queue-type">>, longstr, <<"quorum">>}]}),
    close(Connection, Channel).

channel() ->
    {ok, Connection} = amqp_connection:start(#amqp_params_network{}),
    {ok, Channel} = amqp_connection:open_channel(Connection),
    {Connection, Channel}.

close(Connection, Channel) ->
    amqp_channel:close(Channel),
    amqp_connection:close(Connection).
ESCRIPT
chmod 700 /tmp/quorum.escript
EOF
}
run_quorum() {
  timeout 60 docker exec "$container" sh -c 'ERL_LIBS=/opt/rabbitmq/plugins exec escript /tmp/quorum.escript "$@"' sh "$@"
}

install_quorum_client
run_quorum publish "$queue" "$upgrade_payload"
assert_runtime_state
node_before=$(docker exec "$container" rabbitmqctl eval 'io:format("~s", [atom_to_list(node())]).')
node_before=${node_before%ok}

docker stop "$container" >/dev/null
docker rm "$container" >/dev/null
docker run -d --name "$container" --hostname "$hostname" -v "$volume:/var/lib/rabbitmq" "$image" >/dev/null
wait_for_rabbitmq
rabbitmq_version=$(docker exec "$container" rabbitmqctl version)
otp_version=$(docker exec "$container" rabbitmq-diagnostics -q erlang_version)
otp_version=${otp_version#Erlang/OTP }
otp_version=${otp_version%% *}
openssl_version=$(docker exec "$container" erl -noshell -eval '
  [{<<"OpenSSL">>, _, Version}] = crypto:info_lib(),
  [<<"OpenSSL">>, Number | _] = binary:split(Version, <<" ">>, [global]),
  io:format("~s", [Number]).
' -s init stop)
version_at_least "$rabbitmq_version" 4.3.4 || fail "RabbitMQ $rabbitmq_version is below 4.3.4"
[ "$rabbitmq_version" = "$image_rabbitmq_version" ] || fail "runtime RabbitMQ $rabbitmq_version does not match image version $image_rabbitmq_version"
version_at_least "$otp_version" 27.3.4.15 || fail "OTP $otp_version is below 27.3.4.15"
version_at_least "$otp_version" 28 && fail "OTP $otp_version must be below 28"
case $openssl_version in 3.5.8*) ;; *) fail "unexpected OpenSSL version $openssl_version" ;; esac
crypto_library=$(docker exec "$container" erl -noshell -eval 'io:format("~s", [filename:join([code:priv_dir(crypto), "lib", "crypto.so"])]).' -s init stop)
docker exec "$container" sh -c "ldd '$crypto_library' | grep -q '/opt/openssl'" || fail "Erlang crypto is not linked to /opt/openssl"
install_quorum_client
assert_runtime_state
run_quorum verify "$queue" 1
node_after=$(docker exec "$container" rabbitmqctl eval 'io:format("~s", [atom_to_list(node())]).')
node_after=${node_after%ok}
[ "$node_before" = "$node_after" ] || fail "node identity changed after upgrade"
run_quorum consume "$queue" "$upgrade_payload"
run_quorum verify "$queue" 0
assert_runtime_state
run_quorum publish "$queue" "$restart_payload"
run_quorum verify "$queue" 1
node_before=$(docker exec "$container" rabbitmqctl eval 'io:format("~s", [atom_to_list(node())]).')
node_before=${node_before%ok}

docker stop "$container" >/dev/null
docker start "$container" >/dev/null
wait_for_rabbitmq
assert_runtime_state
run_quorum verify "$queue" 1
node_after=$(docker exec "$container" rabbitmqctl eval 'io:format("~s", [atom_to_list(node())]).')
node_after=${node_after%ok}
[ "$node_before" = "$node_after" ] || fail "node identity changed after restart"
run_quorum consume "$queue" "$restart_payload"
run_quorum verify "$queue" 0
assert_runtime_state
