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
      jq \
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
RUN apt-get update && \
    apt-get install -y curl unzip && \
    rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2 (official)
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip" && \
    unzip /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip


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
# COPY ./bin /YCSB/bin
# COPY ./core /YCSB/core
# COPY ./catalog /YCSB/catalog
COPY ./workloads/lst /YCSB/workloads/lst

# Ensure scripts are executable
RUN chmod +x /YCSB/bin/lst.sh /YCSB/bin/ycsb.sh

# Set environment variables
ENV CLOUD="" \
    THREAD_RANGE="1..16" \
    RUNS="5" \
    CLIENT="direct" \
    SKIP_UPLOAD="false" \
    GCP_BUCKET="lst-consistency" \
    S3_BUCKET="lst-pbafvfgrapl" \
    AZURE_BUCKET="lstx-consistency"

# Entry point to benchmark runner
ENTRYPOINT ["/bin/bash", "/YCSB/bin/lst.sh"]
