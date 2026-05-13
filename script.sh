for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  capacity=$(oc get node $node -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null)
  [ -z "$capacity" ] && continue
  used=$(oc get pods -A --field-selector spec.nodeName=$node -o json | \
    jq '[.items[].spec.containers[].resources.requests["nvidia.com/gpu"] // "0" | tonumber] | add // 0')
  available=$((capacity - used))
  echo "$node | capacity=$capacity | used=$used | available=$available"
done
