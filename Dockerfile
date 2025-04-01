FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install dependencies and tools with better error handling
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
RUN pip3 install --no-cache-dir awscli

# from https://cloud.google.com/sdk/docs/install#deb
# RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | \
#       tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
#       curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
#       gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg && \
#       apt-get update -y && apt-get install google-cloud-cli -y

# Install Google Cloud SDK with better error handling
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" | \
      tee /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl -sSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
      gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg && \
    apt-get update && \
    apt-get install -y google-cloud-sdk && \
    rm -rf /var/lib/apt/lists/*

# Install AzCopy with better error handling
RUN curl -sSL https://aka.ms/downloadazcopy-v10-linux | tar -xz -C /tmp && \
    cp /tmp/azcopy_linux_amd64*/azcopy /usr/bin/ && \
    chmod +x /usr/bin/azcopy && \
    rm -rf /tmp/azcopy_linux_amd64*

# Create workdir and copy files
WORKDIR /YCSB

# Copy the benchmark files
COPY . /YCSB/

# Ensure scripts are executable
RUN chmod +x /YCSB/bin/lst.sh /YCSB/bin/ycsb.sh

# Set environment variables
ENV CLOUD="" \
    THREAD_RANGE="1..16" \
    RUNS="10" \
    SKIP_UPLOAD="false" \
    GCP_BUCKET="lst-consistency" \
    S3_BUCKET="casalog" \
    AZURE_BUCKET="lst-consistency"

# Entry point to benchmark runner
ENTRYPOINT ["/bin/bash", "/YCSB/bin/lst.sh"]
