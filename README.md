# GS-Softwares

Catalogo centralizado de softwares corporativos para **Linux Mint**, usado pela interface **Software** da Frota de PCs.

## Estrutura

Cada aplicativo possui sua pasta:

```
software-name/
├── README.md       # Documentacao e passo a passo manual
├── install.json    # Metadados de instalacao (comandos, URLs, dependencias)
├── install.sh      # Instalacao automatizada no Linux Mint
├── metadata.json   # Dados exibidos na interface da Frota de PCs
└── downloads/      # Icones e checksums (sem binarios proprietarios)
```

## Softwares iniciais

| Pasta | Aplicativo |
|-------|------------|
| `slack/` | Slack |
| `cursor/` | Cursor |
| `whatsapp-web/` | WhatsApp Web |
| `google-chrome/` | Google Chrome |
| `google-drive/` | Google Drive (rclone bisync por usuario) |
| `remmina/` | Remmina |
| `ads-power/` | ADS Power |

## Principios

- **Sem binarios no GitHub** quando houver restricao de licenca.
- Apenas **URLs oficiais** dos fabricantes em `install.json`.
- **Checksums** opcionais para validacao de integridade.
- **Modular**: adicione um software criando uma nova pasta no padrao acima e inclua o slug em `catalog.json`.

## Regenerar estrutura

```bash
python3 tools/bootstrap_catalog.py
```

## Integracao com a Frota de PCs

Configure no ambiente (ou `~/.config/pc-fleet/`):

```bash
export GS_SOFTWARES_REPO="TI04-Gsconsig/GS-Softwares"
export GS_SOFTWARES_BRANCH="main"
```

A aba **Software** consulta `catalog.json` e os arquivos de cada pasta via GitHub (com cache local).

Quando a organizacao **TI05-GSCONSIG** estiver disponivel, altere `GS_SOFTWARES_REPO` para `TI05-GSCONSIG/GS-Softwares`.

## Licenca

Scripts e metadados internos. Cada software obedece a licenca do fabricante; downloads sao feitos apenas dos sites oficiais.
