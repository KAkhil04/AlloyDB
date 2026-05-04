echo "API,RemovedInRelease,Namespace,ServiceAccount,UserAgent,RequestCount" > deprecated_api_audit.csv

oc get apirequestcounts \
  -o jsonpath='{range .items[?(@.status.removedInRelease!="")]}{.metadata.name}{" "}{.status.removedInRelease}{"\n"}{end}' \
  | while read api version; do
      oc get apirequestcounts "$api" \
        -o jsonpath='{range .status.last24h[*].byNode[*].byUser[*]}{.username}{"\t"}{.userAgent}{"\t"}{.requestCount}{"\n"}{end}' \
        | sort -u \
        | while IFS=$'\t' read user agent count; do
            ns=$(echo "$user" | cut -d: -f4)
            sa=$(echo "$user" | cut -d: -f5)
            echo "$api,$version,$ns,$sa,$agent,$count"
          done
    done >> deprecated_api_audit.csv
