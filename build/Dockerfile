FROM registry.access.redhat.com/ubi8/ubi-minimal:latest

ENV OPERATOR=/usr/local/bin/jenkins-operator \
    OPERATOR_NAME=jenkins-operator \
    USER_NAME=jenkins-operator

# install operator binary
COPY build/_output/bin/kubernetes-operator ${OPERATOR}
CMD [ "/usr/local/bin/jenkins-operator" ]
