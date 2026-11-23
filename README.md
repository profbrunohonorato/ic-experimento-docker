# Catálogo de Tecnologias — Contêineres e CI/CD

Continuação da aula de segurança ([ic-experimento-seguranca](https://github.com/profbrunohonorato/ic-experimento-seguranca)), alinhada ao material da **Aula 6 — Contêineres e CI/CD** (`AULA.md`). O catálogo React/Vite e todo o pipeline de qualidade e segurança são mantidos. A evolução desta aula empacota a aplicação em uma **imagem Docker** e a **implanta automaticamente em uma máquina própria** por meio de um **self-hosted runner** do GitHub Actions (Opção B da atividade).

## O que mudou da aula anterior

| Arquivo | Novo? | Papel |
| --- | --- | --- |
| `Dockerfile` | Sim | Build multi-stage: Node.js compila, Nginx serve `dist/` |
| `.dockerignore` | Sim | Mantém o contexto de build pequeno e sem segredos |
| `compose.yaml` | Sim | Executa o contêiner na porta 8080, com healthcheck |
| `.github/workflows/ci.yml` | Alterado | Jobs `docker-build` (GitHub) e `deploy` (self-hosted) |
| `.gitignore` | Alterado | Ignora também `*.tar` gerado pelo `docker save` |

O restante (ESLint, Vitest, cobertura, Semgrep, `npm audit`, Gitleaks, SBOM e Security Gate) é idêntico ao projeto de segurança. Consulte o README daquele repositório para os detalhes desses controles.

## Estrutura

```text
ic-docker/
├── .github/
│   └── workflows/
│       └── ci.yml          ← alterado: docker-build + deploy
├── src/                    aplicação React (sem alterações)
├── .semgrep.yml            regras SAST
├── .gitleaks.toml          regras de secret scanning
├── package.json
├── package-lock.json
├── Dockerfile              ← novo
├── .dockerignore           ← novo
└── compose.yaml            ← novo
```

## Execução local sem Docker

Node.js 22 e npm 11.21.1 (os mesmos do CI e do Dockerfile):

```bash
npm install --global npm@11.21.1
npm ci
npm run dev        # servidor de desenvolvimento do Vite
npm run lint
npm run coverage
```

## Dockerfile — multi-stage build

```dockerfile
# Etapa 1 — Build
FROM node:22-alpine@sha256:1314fb30... AS build
WORKDIR /app
COPY package*.json ./
RUN npm install -g npm@11.21.1 \
    && npm ci
COPY . .
RUN npm run build

# Etapa 2 — Execução
FROM nginx:alpine@sha256:fb465858...
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
```

- **Etapa `build`:** instala as dependências exatamente como o lockfile define (`npm ci`) e gera `dist/`.
- **Etapa final:** contém apenas Nginx e os arquivos estáticos. Node.js, `node_modules` e o código-fonte ficam fora da imagem final (≈ 63 MB), reduzindo tamanho e superfície de ataque.
- **Cache de camadas:** `package*.json` é copiado antes do código. Alterar só `src/` reaproveita a camada do `npm ci`.
- **Imagens fixadas por digest:** a tag (`22-alpine`, `alpine`) é apenas legível e pode mudar; o `@sha256:` garante que o build use sempre o mesmo conteúdo. Os digests foram validados em 23/11/2026. Para atualizar, faça `docker pull` da tag, consulte `docker image inspect --format '{{index .RepoDigests 0}}' <imagem>` e teste antes de trocar.

### .dockerignore

Exclui do contexto `node_modules`, `dist`, `coverage`, `reports`, `.git`, `.github`, `.env*`, `.venv`, arquivos `*.tar`/`*.zip`, a documentação e os próprios arquivos Docker. Isso evita copiar dependências do host (que podem ter binários de outro sistema), acelera o envio do contexto e impede que um `.env` local entre na imagem.

### Construir e executar manualmente

```bash
docker build -t catalogo:1.0 .
docker run -d --name catalogo -p 127.0.0.1:8080:80 catalogo:1.0
# http://localhost:8080
docker rm -f catalogo
```

## Docker Compose

```yaml
name: catalogo
services:
  catalogo:
    build: .
    image: catalogo:1.0
    container_name: catalogo
    ports:
      - "127.0.0.1:${CATALOGO_PORTA:-8080}:80"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1/"]
```

```bash
docker compose up -d --build --wait   # constrói, inicia e espera ficar healthy
docker compose ps
docker compose logs -f
docker compose down
```

- `name: catalogo` fixa o nome do projeto Compose: o deploy do runner sempre substitui o mesmo contêiner, qualquer que seja a pasta do checkout.
- A porta é publicada somente em `127.0.0.1`, não na rede local.
- Se a porta 8080 já estiver em uso, troque-a sem editar o arquivo: `CATALOGO_PORTA=8081 docker compose up -d --build --wait`.
- `restart: unless-stopped` reinicia o contêiner após reboot do Docker, exceto se ele foi parado manualmente.

## Pipeline CI/CD

```text
qualidade ─┐
sast      ─┤
sca       ─┼→ build (React + SBOM) → docker-build → deploy
segredos  ─┘   [Security Gate]        [GitHub]      [self-hosted]
```

| Job | Onde executa | Quando | O que faz |
| --- | --- | --- | --- |
| `qualidade`, `sast`, `sca`, `segredos` | `ubuntu-latest` | push, PR, manual | Controles da aula anterior |
| `build` | `ubuntu-latest` | após os 4 controles | `npm run build` + SBOM |
| `docker-build` | `ubuntu-latest` | após `build` | `docker build`, smoke test com `curl`, `docker save` → artefato `imagem-catalogo` |
| `deploy` | `[self-hosted, linux, x64]` | só push/manual na `main` | `docker compose up -d --build --wait` e verificação HTTP |

Detalhes do job `deploy`:

- **Não executa em pull requests.** Um PR poderia alterar o workflow ou o `Dockerfile` e executar comandos arbitrários na sua máquina; por isso, o runner só recebe código já integrado à `main`.
- **`concurrency: deploy-catalogo`** impede dois deploys simultâneos; um push novo espera o anterior.
- **`environment: local`** registra cada implantação na aba *Deployments* do repositório, com link para a aplicação.
- **Porta configurável:** se a máquina do runner usar outra porta, crie a Variable de repositório `CATALOGO_PORTA` (*Settings → Secrets and variables → Actions → Variables*).
- **`docker image prune -f`** remove imagens antigas sem tag, deixadas a cada novo build.

## Configurar o self-hosted runner (Opção B)

Pré-requisitos na máquina: Linux x64, Docker Engine com o plugin Compose v2, `curl` e `git`.

### 1. Permitir que o usuário use o Docker

O runner **não deve** rodar como root. Use um usuário comum que pertença ao grupo `docker`:

```bash
sudo usermod -aG docker "$USER"
newgrp docker            # ou encerre a sessão e entre novamente
docker run --rm hello-world
```

> Pertencer ao grupo `docker` equivale, na prática, a ter acesso de root no host. Use o runner apenas com repositórios privados ou com workflows e código em que você confia.

### 2. Registrar o runner

No GitHub: **Settings → Actions → Runners → New self-hosted runner**, escolha **Linux / x64** e siga os comandos exibidos. Eles têm o formato abaixo; copie a versão e o token **da página**, pois o token expira em uma hora:

```bash
mkdir ~/actions-runner && cd ~/actions-runner
curl -o actions-runner-linux-x64-<versão>.tar.gz -L \
  https://github.com/actions/runner/releases/download/v<versão>/actions-runner-linux-x64-<versão>.tar.gz
echo "<sha256-exibido-na-página>  actions-runner-linux-x64-<versão>.tar.gz" | sha256sum -c
tar xzf ./actions-runner-linux-x64-<versão>.tar.gz

./config.sh --url https://github.com/<usuario>/<repositorio> --token <TOKEN>
```

Aceite os rótulos padrão (`self-hosted`, `Linux`, `X64`); são eles que o `runs-on: [self-hosted, linux, x64]` do workflow seleciona.

### 3. Deixar o runner escutando (listener)

Para testes, em primeiro plano:

```bash
./run.sh
# √ Connected to GitHub
# Listening for Jobs
```

Para manter o listener ativo após fechar o terminal ou reiniciar a máquina, instale-o como serviço systemd (executado com o seu usuário, não root):

```bash
sudo ./svc.sh install "$USER"
sudo ./svc.sh start
sudo ./svc.sh status
```

O runner aparece como **Idle** em *Settings → Actions → Runners*. Ele abre uma conexão de saída para o GitHub; não é preciso abrir portas no roteador nem expor a máquina.

> Se o usuário foi adicionado ao grupo `docker` depois de instalar o serviço, reinicie-o (`sudo ./svc.sh stop && sudo ./svc.sh start`) para que o processo receba o novo grupo.

### 4. Disparar e verificar o deploy

```bash
git push origin main      # ou Actions → CI/CD → Run workflow, na main
```

Ao terminar o job `self-hosted-deploy`:

```bash
docker compose -p catalogo ps
curl -I http://localhost:8080
```

Abra `http://localhost:8080` no navegador.

### Remover o runner

```bash
cd ~/actions-runner
sudo ./svc.sh stop && sudo ./svc.sh uninstall
./config.sh remove --token <TOKEN-de-remoção-exibido-no-GitHub>
docker compose -p catalogo down
```

## Opção A — registry local (alternativa)

O job `docker-build` publica `catalogo.tar` como artefato `imagem-catalogo`, mesmo sem self-hosted runner. Para usá-lo:

```bash
docker run -d --name registry -p 127.0.0.1:5000:5000 registry:2

unzip imagem-catalogo.zip
docker load -i catalogo.tar
docker tag catalogo:1.0 localhost:5000/catalogo:1.0
docker push localhost:5000/catalogo:1.0

docker image rm catalogo:1.0 localhost:5000/catalogo:1.0   # prova que o pull busca do registry
docker pull localhost:5000/catalogo:1.0
```

## Evidências para entrega

| Critério | Evidência |
| --- | --- |
| Dockerfile | Build multi-stage Node.js → Nginx (`docker image ls catalogo:1.0`) |
| .dockerignore | Arquivo versionado com as exclusões |
| Docker Compose | Aplicação respondendo em `http://localhost:8080` |
| GitHub Actions | Execução aprovada com `docker-build` após o Security Gate |
| Opção B | Job `self-hosted-deploy` concluído no runner e aba *Deployments* |

## Limites

- A imagem é construída duas vezes: no `docker-build` (validação e artefato) e no runner (deploy). Em produção, o pipeline publicaria a imagem em um registry e o servidor faria `pull` por digest, garantindo que o artefato implantado seja exatamente o testado.
- Nginx roda com a configuração padrão da imagem oficial. Cabeçalhos de segurança, usuário não-root (`nginx-unprivileged`) e varredura da imagem (ex.: Trivy) são extensões possíveis.
- O Compose executa contêineres em um único host; não substitui um orquestrador como Kubernetes.

## Referências

- [Docker — Multi-stage builds](https://docs.docker.com/build/building/multi-stage/)
- [Docker Compose](https://docs.docker.com/compose/)
- [GitHub — Self-hosted runners](https://docs.github.com/en/actions/concepts/runners/self-hosted-runners)
- [GitHub — Configurar o runner como serviço](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/configuring-the-self-hosted-runner-application-as-a-service)
- [GitHub Actions — uso seguro](https://docs.github.com/en/actions/reference/security/secure-use)
