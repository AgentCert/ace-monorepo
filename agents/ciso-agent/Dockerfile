FROM python:3.11.10-slim

RUN ln -sf /bin/bash /bin/sh
RUN apt update -y && apt install -y curl gnupg2 unzip ssh

RUN mkdir /etc/ciso-agent
WORKDIR /etc/ciso-agent

# install dependencies here to avoid too much build time
COPY ./pyproject.toml /etc/ciso-agent
COPY requirements-dev.txt /etc/ciso-agent
RUN pip install -r requirements-dev.txt --no-cache-dir

# install `ansible-playbook`
RUN pip install --upgrade ansible-core jmespath kubernetes==31.0.0 setuptools==70.0.0 --no-cache-dir
RUN ansible-galaxy collection install kubernetes.core community.crypto
RUN echo "StrictHostKeyChecking no" >> /etc/ssh/ssh_config
# install `jq`
RUN apt update -y && apt install -y jq
# install `kubectl`
RUN curl -LO https://dl.k8s.io/release/v1.31.0/bin/linux/$(dpkg --print-architecture)/kubectl && \
    chmod +x ./kubectl && \
    mv ./kubectl /usr/local/bin/kubectl
# install `aws` (need this for using kubectl against AWS cluster)
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install
# install `opa`
RUN curl -L -o opa https://github.com/open-policy-agent/opa/releases/download/v1.0.0/opa_linux_$(dpkg --print-architecture)_static && \
    chmod +x ./opa && \
    mv ./opa /usr/local/bin/opa

COPY src /etc/ciso-agent/src
RUN pip install -e /etc/ciso-agent --no-cache-dir
