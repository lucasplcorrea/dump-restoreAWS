#!/bin/bash

# Configurações gerais do servidor que servirá para consulta e dump
AWS_HOST=""
AWS_PORT=""
AWS_USER=""
AWS_PASSWORD=""

# Configurações gerais do servidor que receberá o restore
LOCAL_HOST=""
LOCAL_PORT=""
LOCAL_USER=""
LOCAL_PASSWORD=""

# Lista de bancos para replicar
DATABASES=("banco1" "banco2" "banco3")

# Pasta para armazenar os dumps (cria uma pasta dentro da pasta atual)
DUMP_DIR="./dumps"
mkdir -p $DUMP_DIR

# Exporta senha para conexão com o banco remoto
export PGPASSWORD=$AWS_PASSWORD

# Função para mostrar barra de progresso
show_progress() {
    pid=$1
    spin='-\|/'
    i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[%s] Processando..." "${spin:$i:1}"
        sleep .1
    done
    printf "\r[✔] Concluído!            \n"
}

# Exporta roles e usuários globais
GLOBAL_DUMP_FILE="$DUMP_DIR/global_roles.sql"
    echo "Exportando roles e usuários globais..."
    pg_dumpall -h "$AWS_HOST" -p "$AWS_PORT" -U "$AWS_USER" --roles-only > "$GLOBAL_DUMP_FILE" 2>&1 &
    show_progress $!
    if [ $? -ne 0 ]; then
        echo "[x] Erro ao exportar roles e usuários globais. Verifique o log acima."
        exit 1
    fi
    echo "[✔] Roles e usuários globais exportados com sucesso!"

# Processa cada banco da lista
for DB in "${DATABASES[@]}"; do
    echo "==== Banco de Dados: $DB ===="

    # Testa a conexão com o banco remoto
    # Nessa versão ele presume que o seu postgres é igual ao postgres remoto, porém caso tenha mais de uma versão do postgres instalada você pode passar o caminho absoluto do componente, exemplo: "/usr/pgsql-15/bin/pg_isready"
    echo "Testando conexão com o banco $DB na AWS em $AWS_HOST:$AWS_PORT..."
    pg_isready -h "$AWS_HOST" -p "$AWS_PORT" -U "$AWS_USER" -d "$DB" 2>&1
    CONN_STATUS=$?

    if [ $CONN_STATUS -ne 0 ]; then
        echo "[x] Erro de conexão com o banco $DB na AWS. Detalhes:"
        echo "Comando executado: pg_isready -h $AWS_HOST -p $AWS_PORT -U $AWS_USER -d $DB"
        echo "Resultado: $CONN_STATUS"
        continue
    else
        echo "[✔] Conexão com o banco $DB na AWS estabelecida."
    fi

    echo "Iniciando dump do banco $DB..."
    DUMP_FILE="$DUMP_DIR/dump_$DB.sql"

    # Realiza o dump
    # Nessa versão ele presume que o seu postgres é igual ao postgres remoto, porém caso tenha mais de uma versão do postgres instalada você pode passar o caminho absoluto do componente, exemplo: "/usr/pgsql-15/bin/pg_dump"
    pg_dump -h $AWS_HOST -p $AWS_PORT -U $AWS_USER -F c -d $DB -f $DUMP_FILE 2>&1 &
    show_progress $!
    if [ $? -ne 0 ]; then
        echo "[x] Erro ao criar o dump do banco $DB. Verifique o log acima."
        continue
    fi

    # Testa a conexão local
    # Nessa versão ele presume que o seu postgres é igual ao postgres remoto, porém caso tenha mais de uma versão do postgres instalada você pode passar o caminho absoluto do componente, exemplo: "/usr/pgsql-15/bin/pg_isready"
    export PGPASSWORD=$LOCAL_PASSWORD
    echo "Testando conexão com o servidor local para o banco $DB..."
    pg_isready -h $LOCAL_HOST -p $LOCAL_PORT -U $LOCAL_USER -d postgres 2>&1
    LOCAL_CONN_STATUS=$?

    if [ $LOCAL_CONN_STATUS -ne 0 ]; then
        echo "[x] Falha ao conectar no servidor local. Detalhes:"
        echo "Comando executado: pg_isready -h $LOCAL_HOST -p $LOCAL_PORT -U $LOCAL_USER -d postgres"
        echo "Resultado: $LOCAL_CONN_STATUS"
        continue
    else
        echo "[✔] Conexão com o servidor local estabelecida."
    fi

    # Restaurar roles e usuários globais localmente
echo "Restaurando roles e usuários globais no servidor local..."
export PGPASSWORD=$LOCAL_PASSWORD
psql -h $LOCAL_HOST -p $LOCAL_PORT -U $LOCAL_USER -d postgres -f "$GLOBAL_DUMP_FILE" 2>&1 &
show_progress $!
if [ $? -ne 0 ]; then
    echo "[x] Erro ao restaurar roles e usuários globais. Verifique o log acima."
    exit 1
fi
echo "[✔] Roles e usuários globais restaurados com sucesso!"

    # Restaura o banco local
    # Nessa versão ele presume que o seu postgres é igual ao postgres remoto, porém caso tenha mais de uma versão do postgres instalada você pode passar o caminho absoluto do componente, exemplo: "/usr/pgsql-15/bin/pg_restore"
    echo "Restaurando banco $DB localmente (sobrescrevendo caso já exista)..."
    pg_restore -h $LOCAL_HOST -p $LOCAL_PORT -U $LOCAL_USER -d postgres --clean --create $DUMP_FILE 2>&1 &
    show_progress $!
    if [ $? -ne 0 ]; then
        echo "[x] Erro ao restaurar o banco $DB localmente. Verifique o log acima."
        continue
    fi

    echo "[✔] Banco $DB restaurado com sucesso!"
    echo "==== Fim do processo para o banco $DB ===="
done

echo "Processo finalizado para todos os bancos!"
