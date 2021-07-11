FROM python:3.8-slim

RUN apt update && apt install -y curl jq docker.io \
  && curl -L https://kind.sigs.k8s.io/dl/v0.7.0/kind-Linux-amd64 \
    -o /usr/local/bin/kind && chmod +x /usr/local/bin/kind \
  && curl -L https://storage.googleapis.com/kubernetes-release/release/v1.18.3/bin/linux/amd64/kubectl \
    -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl \
  && curl -L https://get.helm.sh/helm-v2.16.9-linux-amd64.tar.gz \
    | tar -zx --strip-components=1 --directory=/usr/local/bin linux-amd64/helm

# RUN apt update && apt install -y curl jq docker.io \
#   && curl -L https://kind.sigs.k8s.io/dl/v0.8.1/kind-Linux-amd64 \
#     -o /usr/local/bin/kind && chmod +x /usr/local/bin/kind \
#   && curl -L https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kubectl \
#     -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl \
#   && curl -L https://get.helm.sh/helm-v3.3.0-rc.2-linux-amd64.tar.gz \
#     | tar -zx --strip-components=1 --directory=/usr/local/bin linux-amd64/helm

COPY ./kube-app-testing.sh /usr/local/bin

CMD ["kube-app-testing.sh", "-h"]
