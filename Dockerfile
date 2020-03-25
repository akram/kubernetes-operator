FROM centos:7 as build-tools
ENV LANG=en_US.utf8 \ 
    GOPATH /tmp/go \
    GO_VERSION=1.13.0 \
    GO_OS=linux \
    GO_ARCH=amd64 \
    GO_PACKAGE_NAME=go${GO_VERSION}.${GO_OS}-${GO_ARCH}.tar.gz \
    OPERATOR_SDK_VERSION=v0.15.0

ARG GO_PACKAGE_PATH=github.com/redhat-developer/openshift-jenkins-operator

ENV GIT_COMMITTER_NAME devtools
ENV GIT_COMMITTER_EMAIL devtools@redhat.com
ENV PATH=:$GOPATH/bin:/tmp/goroot/go/bin:$PATH
WORKDIR /tmp

RUN mkdir -p $GOPATH/bin
RUN mkdir -p /tmp/goroot

RUN curl -Lo $GO_PACKAGE_NAME https://dl.google.com/go/$GO_PACKAGE_NAME && tar -C /tmp/goroot -xzf $GO_PACKAGE_NAME
RUN curl -Lo kubectl https://storage.googleapis.com/kubernetes-release/release/v1.14.3/bin/linux/amd64/kubectl && chmod +x kubectl && mv kubectl $GOPATH/bin/

RUN curl -Lo operator-sdk https://github.com/operator-framework/operator-sdk/releases/download/$OPERATOR_SDK_VERSION/operator-sdk-$OPERATOR_SDK_VERSION-x86_64-linux-gnu && \
    chmod +x operator-sdk && mv operator-sdk $GOPATH/bin/ && \
    mkdir -p ${GOPATH}/src/${GO_PACKAGE_PATH}/

WORKDIR ${GOPATH}/src/${GO_PACKAGE_PATH}
ENTRYPOINT [ "/bin/bash" ]

