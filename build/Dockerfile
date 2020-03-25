FROM registry.access.redhat.com/ubi8/ubi-minimal:latest

ENV OPERATOR=/usr/local/bin/jenkins-operator \
    USER_UID=1001 \
    OPERATOR_NAME=jenkins-operator \
    USER_NAME=jenkins-operator

# install operator binary
COPY build/_output/bin/$OPERATOR_NAME ${OPERATOR}
COPY build/bin /usr/local/bin
RUN  /usr/local/bin/user_setup
ENTRYPOINT ["/usr/local/bin/entrypoint"]
USER ${USER_UID}
