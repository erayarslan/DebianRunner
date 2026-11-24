#!/bin/sh
# Debian APT package manager wrapper invoked from native UI with literal argv.
# No eval, shell expressions, or arbitrary options.
set -eu
umask 077
cd "$(dirname "$0")"
. ./support-common.sh
. ./package-lock.sh
verify_resources
operation=${1:-}; value=${2:-}
case "$operation" in installed|search|details|updates|update|install|upgrade|remove|diagnose|configure|dependencies|repair|catalog|plan-install|plan-remove|plan-upgrade|apply-install|apply-remove|apply-upgrade) ;; *) echo 'PACKAGE_OPERATION: invalid operation'; exit 2;; esac
case "$operation" in
 search|details|install|upgrade|remove|plan-*|apply-*)
  [ -n "$value" ] && [ "${#value}" -le 128 ] || { echo 'PACKAGE_OPERATION: empty or oversized name'; exit 2; }
  case "$value" in -*|*[!a-zA-Z0-9+._:-]*) echo 'PACKAGE_OPERATION: invalid name'; exit 2;; esac;;
esac
command -v apt-get >/dev/null || { echo 'PACKAGE_OPERATION: apt-get is unavailable'; exit 2; }
package_lock_acquire || exit $?
for file in package-catalog-meta.tmp package-plan.tsv package-plan.txt package-plan.tsv.new package-catalog.tsv package-catalog.tsv.new package-operation.log package-result package-state.tsv package-details.txt package-interrupted package-operation.previous.log package-output.tmp package-search.tmp package-installed.tmp package-state.tsv.new package-details.txt.new package-result.new; do
 [ ! -L "$file" ] || { echo 'PACKAGE_OPERATION: unsafe managed file'; exit 2; }
done
distro=debian
printf 'operation=%s\ndistribution=%s\nstarted=%s\n' "$operation" "$distro" "$(date +%s)" > package-interrupted
printf 'running\n' > package-result
rm -f package-state.tsv.new package-details.txt.new
mv -f package-operation.log package-operation.previous.log 2>/dev/null || true
: > package-operation.log

catalog_names() { [ -r catalog-debian.tsv ] && awk -F '\t' '$1!="" && $1!~/^#/ {print $1}' catalog-debian.tsv; }
catalog_join() {
 awk -F '\t' '$1!="" && $1!~/^#/' catalog-debian.tsv > package-catalog-meta.tmp
 awk 'BEGIN{FS=OFS="\t"} NR==FNR {meta[$1]=$2 OFS $3 OFS $4;next} ($1 in meta) {print $1,$2,$3,$4,$5,meta[$1]}' package-catalog-meta.tmp - > package-catalog.tsv.new
 rm -f package-catalog-meta.tmp
 mv package-catalog.tsv.new package-catalog.tsv; wc -l < package-catalog.tsv | sed 's/^/PACKAGE_CATALOG: entries=/'
}
perform_catalog() {
 names=$(catalog_names | tr '\n' ' ')
 [ -n "$names" ] || { echo 'PACKAGE_CATALOG: no Debian catalog available'; return 2; }
 dpkg-query -W -f='${Package}\t${db:Status-Abbrev}\n' > package-installed.tmp
 # shellcheck disable=SC2086
 apt-cache --no-all-versions show -- $names 2>/dev/null > package-search.tmp || true
 awk 'BEGIN{FS=OFS="\t"} NR==FNR {if($2~/^ii/)inst[$1]=1;next} /^Package: / {p=substr($0,10);v="";a="";d=""} /^Version: / {v=substr($0,10)} /^Architecture: / {a=substr($0,15)} /^Description(-[a-zA-Z_]+)?: / {d=$0;sub(/^[^:]*: /,"",d)} /^$/ {if(p!=""){print p,v,a,(p in inst?"installed":"available"),d;p=""}} END {if(p!="")print p,v,a,(p in inst?"installed":"available"),d}' package-installed.tmp package-search.tmp | catalog_join
 rm -f package-installed.tmp package-search.tmp
}
perform_plan() {
 kind=${operation#plan-}
 case "$kind" in
  install) apt-get -s install --no-install-recommends --no-remove -- "$value";;
  upgrade) apt-get -s install --only-upgrade --no-install-recommends --no-remove -- "$value";;
  remove) apt-get -s remove -- "$value";;
 esac > package-plan.txt
 awk 'BEGIN{OFS="\t"} /^Inst / {v=($3~/^\[/)?$4:$3;gsub(/[()]/,"",v);print (($3~/^\[/)?"upgrade":"install"),$2,v} /^Remv / {v=$3;gsub(/[][]/,"",v);print "remove",$2,v}' package-plan.txt > package-plan.tsv.new
 cat package-plan.txt
 mv package-plan.tsv.new package-plan.tsv
 echo "PACKAGE_PLAN: kind=$kind changes=$(wc -l < package-plan.tsv | tr -d ' ')"
}
perform_apply() {
 kind=${operation#apply-}
 echo "PACKAGE_STAGE: Applying the reviewed $kind of $value"
 case "$kind" in
  install) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --no-remove -- "$value";;
  upgrade) DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade --no-install-recommends --no-remove -- "$value";;
  remove) DEBIAN_FRONTEND=noninteractive apt-get remove -y -- "$value";;
 esac
}
perform() {
 echo "PACKAGE_OPERATION: distribution=$distro operation=$operation started=$(date +%s)"
 case "$operation" in
  catalog) perform_catalog; return $?;;
  plan-*) perform_plan; return $?;;
  apply-*) perform_apply; return $?;;
  installed)
   dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\t${db:Status-Abbrev}\n' > package-state.tsv.new
   head -n 2000 package-state.tsv.new; mv package-state.tsv.new package-state.tsv;;
  search)
   apt-cache search --names-only -- "$value" > package-search.tmp
   set --
   while read -r name rest; do
    [ "${#name}" -le 128 ] || continue
    case "$name" in ''|-*|*[!a-zA-Z0-9+._:-]*) continue;; esac
    set -- "$@" "$name"; [ "$#" -lt 200 ] || break
   done < package-search.tmp
   dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${db:Status-Abbrev}\n' > package-installed.tmp
   if [ "$#" -gt 0 ]; then
    apt-cache --no-all-versions show -- "$@" > package-search.tmp
    awk 'BEGIN{FS="\t";OFS="\t"} NR==FNR {installed[$1]=$4;next} /^Package: / {p=substr($0,10);v="";a="";d=""} /^Version: / {v=substr($0,10)} /^Architecture: / {a=substr($0,15)} /^Description(-[a-zA-Z_]+)?: / {d=$0;sub(/^[^:]*: /,"",d)} /^$/ {if(p!=""){print p,v,a,(p in installed?installed[p]:"not installed"),d;p=""}} END {if(p!="")print p,v,a,(p in installed?installed[p]:"not installed"),d}' package-installed.tmp package-search.tmp > package-state.tsv.new
   else : > package-state.tsv.new; fi
   rm -f package-installed.tmp
   cat package-state.tsv.new; mv package-state.tsv.new package-state.tsv; rm -f package-search.tmp;;
  details)
   apt-cache show -- "$value" > package-details.txt.new
   dpkg-query -W -f='Installed state: ${Status}\n' "$value" >> package-details.txt.new 2>/dev/null || true
   cat package-details.txt.new; mv package-details.txt.new package-details.txt;;
  updates)
   apt list --upgradable;;
  update)
   apt-get update;;
  install)
   DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends --no-remove -y -- "$value";;
  upgrade)
   apt-get --simulate install --only-upgrade --no-install-recommends --no-remove -- "$value"
   echo 'Confirm named-package upgrade by typing yes:'
   read -r answer; [ "$answer" = yes ] || return 1
   apt-get install --only-upgrade --no-install-recommends --no-remove -- "$value";;
  remove)
   apt-get remove -- "$value";;
  diagnose)
   cat /proc/ish/tasks 2>/dev/null || true
   dpkg --audit || true
   apt-get check || true
   for file in /etc/passwd /etc/group /etc/shadow /etc/gshadow; do [ ! -e "$file" ] || stat -c 'ACCOUNT_METADATA: path=%n mode=%a uid=%u gid=%g' "$file"; done;;
  configure|repair)
   checkpoint=$(mktemp -d /var/lib/linuxrunner/repair-checkpoints/repair.XXXXXX)
   cp -p /var/lib/dpkg/status "$checkpoint/dpkg-status"
   dpkg --audit || true
   dpkg --force-confdef --force-confold --configure -a
   if [ "$operation" = repair ]; then apt-get -f install; fi
   echo "PACKAGE_REPAIR: metadata_checkpoint=$checkpoint rollback=manual-not-automatic";;
  dependencies)
   apt-get check;;
 esac
}
mkdir -p /var/lib/linuxrunner/repair-checkpoints
operation_signal=0
trap 'operation_signal=130' INT
exec 3<&0
(
 set -e
 perform
) <&3 3<&- > package-output.tmp 2>&1 & worker=$!
exec 3<&-
tail -n +1 -f package-output.tmp & reader=$!
code=0; wait "$worker" || code=$?
if [ "$operation_signal" -ne 0 ]; then
 while kill -0 "$worker" 2>/dev/null; do wait "$worker" || code=$?; done
 code=$operation_signal
 echo 'PACKAGE_OPERATION: interrupted; retained state requires diagnosis' >&2
fi
kill "$reader" 2>/dev/null || true; wait "$reader" 2>/dev/null || true
tail -c 1048576 package-output.tmp > package-operation.log
rm -f package-output.tmp
printf '\nPACKAGE_OPERATION: distribution=%s operation=%s exit=%s ended=%s\n' "$distro" "$operation" "$code" "$(date +%s)" >> package-operation.log
tail -n 20 package-operation.log
printf '%s\n' "$code" > package-result.new; mv package-result.new package-result
[ "$code" -ne 0 ] || rm -f package-interrupted
exit "$code"
