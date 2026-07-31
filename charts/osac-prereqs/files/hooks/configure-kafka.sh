#!/usr/bin/env bash
set -euo pipefail

echo "Waiting for AMQ Streams CSV to appear in osac-kafka namespace..."
until oc get csv --no-headers -n osac-kafka 2>/dev/null | grep -q amqstreams; do
  sleep 10
done
AMQ_CSV=$(oc get csv --no-headers -n osac-kafka | awk '/amqstreams/ { print $1 }' | tail -1)

echo "Waiting for CSV ${AMQ_CSV} to succeed..."
until [[ "$(oc get csv "${AMQ_CSV}" -n osac-kafka -o jsonpath='{.status.phase}')" == "Succeeded" ]]; do
  sleep 10
done

echo "Waiting for AMQ Streams cluster operator deployment..."
oc wait --for=condition=Available deploy -l olm.owner="${AMQ_CSV}" -n osac-kafka --timeout=300s

echo "Applying Kafka cluster..."
oc apply -f /config/kafka-cluster.yaml

echo "Waiting for Kafka cluster to be ready..."
until oc wait kafka/osac-kafka -n osac-kafka --for=condition=Ready --timeout=600s 2>/dev/null; do
  echo "Kafka cluster not yet ready, retrying..."
  sleep 15
done

echo "Kafka configuration complete."
