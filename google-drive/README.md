# Google Drive (Frota de PCs)

Sincronizacao bidirecional do Google Drive via **rclone bisync**, com conta **por usuario Linux**.

## O que a instalacao faz (root, 1x por PC)

- Instala `rclone`, `fuse3` e `zenity`
- Publica scripts e templates em `/usr/local/lib/pc-fleet/gdrive/`
- Instala `fleet-gdrive-wizard` e `fleet-gdrive-disconnect` em `/usr/local/bin/`
- Registra autostart XDG `pc-fleet-gdrive-wizard.desktop`
- Instala unit systemd user `pc-fleet-gdrive-bisync.service` em `/etc/systemd/user/`

**Nao** cria `~/GoogleDrive` nem faz OAuth — isso e responsabilidade do operador no primeiro login grafico.

## Operador

1. Loga na sessao Cinnamon
2. Assistente pede e-mail Google e abre OAuth no navegador
3. Pasta `~/GoogleDrive` sincroniza automaticamente nos logins seguintes

## Remocao (TI)

`remove_commands` no `install.json` remove pacotes apt, binarios e autostart global. Tokens OAuth em `~/.config/rclone/` de cada usuario **nao** sao apagados automaticamente.

## Arquivos em `deploy/`

Copia espelhada dos scripts da Frota (`pc-fleet-dashboard`). O `install.sh` baixa esta pasta do GitHub raw durante a instalacao remota.
