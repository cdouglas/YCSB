FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install dependencies and tools
RUN apt-get update && \
    TZ=Etc/UTC DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      dbus-user-session \
      git \
      gnupg \
      lsb-release \
      openjdk-17-jdk-headless \
      python3-pip \
      software-properties-common \
      ssh \
      unzip \
      wget && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install AWS CLI
RUN pip3 install awscli

# Install Google Cloud SDK (includes gsutil)
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" | \
      tee /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
      apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - && \
    apt-get update && \
    apt-get install -y google-cloud-sdk && \
    rm -rf /var/lib/apt/lists/*

# Install AzCopy
RUN curl -sL https://aka.ms/downloadazcopy-v10-linux | tar -xz -C /opt && \
    mv /opt/azcopy_linux_amd64*/azcopy /usr/bin/azcopy && \
    chmod +x /usr/bin/azcopy

# Copy project files and script
COPY . /YCSB
WORKDIR /YCSB

# Make sure script is executable
RUN chmod +x /YCSB/bin/lst.sh

# Entry point to benchmark runner
ENTRYPOINT ["/bin/bash", "bin/lst.sh"]

