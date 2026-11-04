#!/usr/bin/env bash
# Uma tentativa de criar a VPS ARM grátis da Oracle (Always Free).
# Roda dentro do GitHub Actions. Resultado vai para $GITHUB_OUTPUT:
#   criado | existe | sem_capacidade | muitas_requisicoes
set -u

NOME="${NOME:-servidor-n8n}"
OCPUS="${OCPUS:-2}"
MEMORIA_GB="${MEMORIA_GB:-12}"
DISCO_GB="${DISCO_GB:-100}"
SUBNET_NOME="${SUBNET_NOME:-public subnet-Gabriel}"
SSH_PUB="${SSH_PUB:-$HOME/oracle.pub}"
SHAPE="VM.Standard.A1.Flex"
CONFIG="$HOME/.oci/config"

resultado() { echo "resultado=$1" >> "${GITHUB_OUTPUT:-/dev/null}"; }
log() { echo "[$(date -u '+%d/%m %H:%M:%S') UTC] $*"; }

[ -s "$SSH_PUB" ] || { log "ERRO: chave pública SSH vazia (secret SSH_PUBLIC_KEY)."; exit 1; }
TENANCY=$(grep -m1 '^tenancy' "$CONFIG" | cut -d'=' -f2 | tr -d ' \r')
[ -n "$TENANCY" ] || { log "ERRO: secret OCI_TENANCY vazio."; exit 1; }

AD=$(oci iam availability-domain list --compartment-id "$TENANCY" \
      --query 'data[0].name' --raw-output 2>/tmp/err)
if [ -z "$AD" ] || [ "$AD" = "null" ]; then
  log "ERRO ao ler a availability domain (confira os secrets da API key):"; cat /tmp/err | head -n 15; exit 1
fi

# Não cria duplicado
existentes=$(oci compute instance list --compartment-id "$TENANCY" --display-name "$NOME" \
    --query "length(data[?\"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'])" \
    --raw-output 2>/dev/null)
if [ -n "$existentes" ] && [ "$existentes" != "null" ] && [ "$existentes" -gt 0 ] 2>/dev/null; then
  log "Já existe a instância '$NOME'. Nada a fazer."; resultado existe; exit 0
fi

SUBNET=$(oci network subnet list --compartment-id "$TENANCY" --all \
      --query "data[?\"display-name\"=='$SUBNET_NOME'].id | [0]" --raw-output 2>/dev/null)
[ -n "$SUBNET" ] && [ "$SUBNET" != "null" ] || { log "ERRO: não achei a subnet '$SUBNET_NOME'."; exit 1; }

IMAGEM=$(oci compute image list --compartment-id "$TENANCY" \
      --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
      --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC --limit 1 \
      --query 'data[0].id' --raw-output 2>/dev/null)
[ -n "$IMAGEM" ] && [ "$IMAGEM" != "null" ] || { log "ERRO: não achei a imagem Ubuntu 24.04 ARM."; exit 1; }

log "Tentando criar $SHAPE ($OCPUS OCPU / $MEMORIA_GB GB / $DISCO_GB GB) em $AD..."
saida=$(oci compute instance launch \
    --availability-domain "$AD" \
    --compartment-id "$TENANCY" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORIA_GB}" \
    --image-id "$IMAGEM" \
    --subnet-id "$SUBNET" \
    --assign-public-ip true \
    --boot-volume-size-in-gbs "$DISCO_GB" \
    --ssh-authorized-keys-file "$SSH_PUB" \
    --display-name "$NOME" 2>&1)

if echo "$saida" | grep -q '"lifecycle-state"'; then
  log "SUCESSO! Instância '$NOME' criada."; resultado criado; exit 0
elif echo "$saida" | grep -qi 'capacity'; then
  log "Sem capacidade agora. Próxima tentativa no próximo agendamento."; resultado sem_capacidade; exit 0
elif echo "$saida" | grep -qi 'TooManyRequests'; then
  log "Muitas requisições. Tenta de novo no próximo agendamento."; resultado muitas_requisicoes; exit 0
elif echo "$saida" | grep -qi 'LimitExceeded'; then
  log "ERRO: limite da conta excedido. Diminua OCPUS/MEMORIA_GB/DISCO_GB."; exit 1
elif echo "$saida" | grep -qi 'NotAuthenticated'; then
  log "ERRO: API key inválida. Confira os secrets."; exit 1
else
  log "ERRO inesperado:"; echo "$saida" | head -n 20; exit 1
fi
