# midge — Lançador serializado para aplicações legadas em Terminal Server

Contorno para aplicações legadas que **quebram quando vários usuários abrem
o sistema ao mesmo tempo** em ambiente multissessão (Terminal Server / RDS /
TSplus), exibindo erros do tipo *"Várias tentativas de abertura detectadas"*
ou falhas de acesso concorrente a arquivos de licença.

Caso de referência: DOC-Windows (DeMaria) em Windows Server 2022 + TSplus
Enterprise, ~40 usuários simultâneos. A abordagem serve para qualquer
aplicação com o mesmo padrão de falha.

## O problema

Sistemas dessa geração costumam controlar a abertura com **mutex global** ou
**arquivo de lock/estação** — mecanismos pensados para um usuário por máquina.
Em Terminal Server, as N sessões rodam no mesmo host: duas aberturas
simultâneas disputam o mesmo recurso e a segunda falha.

Sem acesso ao código-fonte do aplicativo, a saída é **serializar as aberturas**:
garantir que apenas um usuário execute a fase crítica de carga por vez.

## O que este lançador faz

1. **Enfileira as aberturas** — quem chega sozinho abre na hora; quem chega
   junto espera a vez, sem janela nem aviso (fila invisível ao usuário).
2. **Mantém a sessão RDP viva** enquanto a aplicação estiver aberta.
3. **Desloga automaticamente** quando o usuário fecha a aplicação.
4. **Auto-recupera** de colisões: se a tela de erro aparecer, mata a instância
   travada e tenta de novo, em vez de deixar a sessão presa.

## Decisões de projeto

| Mecanismo | Por quê |
|---|---|
| Lock = arquivo aberto em modo exclusivo, mantido aberto | Se a sessão cai, o SO fecha o handle e a fila anda sozinha. Elimina trava órfã sem timers de "destravamento forçado" (que furam a fila sob carga) |
| Liberação da fila no próprio processo, após o lançamento | Ancorada no nascimento real do processo da aplicação — não em relógio disparado antes |
| Vigia pelo handle local do processo | Detecção instantânea do fechamento, sem depender de WMI |
| Estado desconhecido nunca gera logoff | Falha de WMI não pode derrubar sessão de usuário com trabalho aberto |
| Consulta WMI que falha conta como "app vivo" | O lado seguro do erro é manter a sessão, não encerrá-la |

O script passou por revisão adversarial (concorrência, semântica VBScript e
modos de falha do ambiente RDS) antes de ir a produção. As correções estão
documentadas em [LEIA-ME - Instalacao.md](pacote-DOCSYS/LEIA-ME%20-%20Instalacao.md).

## Conteúdo

```
pacote-DOCSYS/
├── iniciar.vbs                 # o lançador (publicado no TSplus)
├── instalar.bat                # instalação local (duplo clique, como admin)
├── instalar.ps1                # instalação silenciosa / idempotente
├── desinstalar.bat             # rollback (restaura versão anterior)
├── deploy-multi.ps1            # implantação em massa (N servidores)
├── descobrir-config-tsplus.ps1 # diagnóstico da config do TSplus
├── servidores.exemplo.txt      # modelo da lista de servidores
├── LEIA-ME - Instalacao.md     # instalação, config do TSplus, calibração
└── LEIA-ME - Implantacao em 20 servidores.md
```

## Instalação rápida (um servidor)

1. Copie a pasta `pacote-DOCSYS` para o servidor.
2. `instalar.bat` → botão direito → **Executar como administrador**.
3. Configure o TSplus conforme o LEIA-ME (**essencial** — sem isso o lançador
   não é chamado, ou a sessão cai sozinha).

## Implantação em vários servidores

```powershell
# 1) copie servidores.exemplo.txt para servidores.txt e preencha
# 2) rode de uma máquina com acesso admin aos servidores:
powershell -ExecutionPolicy Bypass -File .\deploy-multi.ps1 -MsTrava 20000
```

Idempotente, paralelo, com relatório em CSV. Detalhes no
[LEIA-ME de implantação](pacote-DOCSYS/LEIA-ME%20-%20Implantacao%20em%2020%20servidores.md).

## Calibração

`MS_TRAVA` (topo do `iniciar.vbs`) é o tempo que cada usuário segura a fila
enquanto a aplicação carrega. É o único parâmetro a ajustar: use o **menor
valor que abre sem nenhum erro** com várias máquinas simultâneas. Os logs em
`C:\DOCSYS\logs\` registram os tempos reais (`SPAWN`, `LIC`, `FILA`) para
embasar o ajuste.

## Limitações

- A fila é um **contorno**, não a correção da causa raiz. A solução definitiva
  depende do fabricante da aplicação (por exemplo, fixar o número de estação
  por sessão em vez de por máquina).
- O custo cresce linearmente com o número de usuários simultâneos.
- A fila é local por servidor. Se vários servidores compartilharem a mesma base
  e a alocação de estação for global, o lock precisa ir para uma pasta de rede.
- VBScript está deprecado pela Microsoft (Feature on Demand a partir do
  Server 2025). Em migração futura, portar para PowerShell.

## Segurança

O `.gitignore` mantém fora do versionamento os arquivos com dados reais:
logs (contêm nomes de usuários), `servidores.txt` (inventário de
infraestrutura) e relatórios de implantação. **Não commite esses arquivos.**

## Licença

MIT — use, adapte e distribua livremente. Sem garantia: valide em ambiente de
teste antes de produção.
