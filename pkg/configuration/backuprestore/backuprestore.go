package backuprestore

import (
	"context"
	"fmt"
	"time"

	"github.com/go-logr/logr"
	"github.com/jenkinsci/kubernetes-operator/api/v1alpha2"
	jenkinsclient "github.com/jenkinsci/kubernetes-operator/pkg/client"
	"github.com/jenkinsci/kubernetes-operator/pkg/configuration"
	"github.com/jenkinsci/kubernetes-operator/pkg/log"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/types"
	k8s "sigs.k8s.io/controller-runtime/pkg/client"
)

type backupTrigger struct {
	interval uint64
	ticker   *time.Ticker
}

type backupTriggers struct {
	triggers map[string]backupTrigger
}

func (t *backupTriggers) stop(logger logr.Logger, namespace string, name string) {
	key := t.key(namespace, name)
	trigger, found := t.triggers[key]
	if found {
		logger.Info(fmt.Sprintf("Stopping backup trigger for '%s'", key))
		trigger.ticker.Stop()
		delete(t.triggers, key)
	} else {
		logger.V(log.VWarn).Info(fmt.Sprintf("Can't stop backup trigger for '%s', not found, skipping", key))
	}
}

func (t *backupTriggers) get(namespace, name string) (backupTrigger, bool) {
	trigger, found := t.triggers[t.key(namespace, name)]

	return trigger, found
}

func (t *backupTriggers) key(namespace, name string) string {
	return namespace + "/" + name
}

func (t *backupTriggers) add(namespace string, name string, trigger backupTrigger) {
	t.triggers[t.key(namespace, name)] = trigger
}

var triggers = backupTriggers{triggers: make(map[string]backupTrigger)}

// BackupAndRestore represents Jenkins backup and restore client . This type extends configuration.Configuration
type BackupAndRestore struct {
	configuration.Configuration
	logger logr.Logger
}

// New returns Jenkins backup and restore client
func New(configuration configuration.Configuration, logger logr.Logger) *BackupAndRestore {
	return &BackupAndRestore{
		Configuration: configuration,
		logger:        logger,
	}
}

// Validate validates backup and restore configuration
func (bar *BackupAndRestore) Validate() []string {
	var messages []string
	allContainers := map[string]v1alpha2.Container{}
	for _, container := range bar.Configuration.Jenkins.Spec.Master.Containers {
		allContainers[container.Name] = container
	}

	restore := bar.Configuration.Jenkins.Spec.Restore
	if len(restore.ContainerName) > 0 {
		_, found := allContainers[restore.ContainerName]
		if !found {
			messages = append(messages, fmt.Sprintf("restore container '%s' not found in CR spec.master.containers", restore.ContainerName))
		}
		if restore.Action.Exec == nil {
			messages = append(messages, "spec.restore.action.exec is not configured")
		}
	}

	backup := bar.Configuration.Jenkins.Spec.Backup
	if len(backup.ContainerName) > 0 {
		_, found := allContainers[backup.ContainerName]
		if !found {
			messages = append(messages, fmt.Sprintf("backup container '%s' not found in CR spec.master.containers", backup.ContainerName))
		}
		if backup.Action.Exec == nil {
			messages = append(messages, "spec.backup.action.exec is not configured")
		}
		if backup.Interval == 0 {
			messages = append(messages, "spec.backup.interval is not configured")
		}
	}

	if len(restore.ContainerName) > 0 && len(backup.ContainerName) == 0 {
		messages = append(messages, "spec.backup.containerName is not configured")
	}
	if len(backup.ContainerName) > 0 && len(restore.ContainerName) == 0 {
		messages = append(messages, "spec.restore.containerName is not configured")
	}

	return messages
}

// Restore performs Jenkins restore backup operation
func (bar *BackupAndRestore) Restore(jenkinsClient jenkinsclient.Jenkins) error {
	jenkins := bar.Configuration.Jenkins
	if len(jenkins.Spec.Restore.ContainerName) == 0 || jenkins.Spec.Restore.Action.Exec == nil {
		bar.logger.V(log.VDebug).Info("Skipping restore backup, backup restore not configured")

		return nil
	}
	if jenkins.Status.RestoredBackup != 0 {
		bar.logger.V(log.VDebug).Info("Skipping restore backup, backup already restored")

		return nil
	}
	if jenkins.Status.LastBackup == 0 {
		bar.logger.V(log.VDebug).Info("Skipping restore backup")
		if jenkins.Status.PendingBackup == 0 {
			jenkins.Status.PendingBackup = 1
			return bar.Client.Update(context.TODO(), jenkins)
		}
		return nil
	}

	var backupNumber uint64
	if jenkins.Spec.Restore.RecoveryOnce != 0 {
		backupNumber = jenkins.Spec.Restore.RecoveryOnce
	} else {
		backupNumber = jenkins.Status.LastBackup
	}
	bar.logger.Info(fmt.Sprintf("Restoring backup '%d'", backupNumber))
	podName := bar.GetJenkinsMasterPodName()
	command := jenkins.Spec.Restore.Action.Exec.Command
	command = append(command, fmt.Sprintf("%d", backupNumber))
	_, _, err := bar.Exec(podName, jenkins.Spec.Restore.ContainerName, command)

	if err == nil {
		_, err := jenkinsClient.ExecuteScript("Jenkins.instance.reload()")
		if err != nil {
			return err
		}

		jenkins.Spec.Restore.RecoveryOnce = 0
		jenkins.Status.RestoredBackup = backupNumber
		jenkins.Status.PendingBackup = backupNumber + 1
		return bar.Client.Update(context.TODO(), jenkins)
	}

	return err
}

// Backup performs Jenkins backup operation
func (bar *BackupAndRestore) Backup(setBackupDoneBeforePodDeletion bool) error {
	jenkins := bar.Configuration.Jenkins
	if len(jenkins.Spec.Backup.ContainerName) == 0 || jenkins.Spec.Backup.Action.Exec == nil {
		bar.logger.V(log.VDebug).Info("Skipping restore backup, backup restore not configured")
		return nil
	}
	if jenkins.Status.PendingBackup == jenkins.Status.LastBackup {
		bar.logger.V(log.VDebug).Info("Skipping backup")
		return nil
	}
	backupNumber := jenkins.Status.PendingBackup
	bar.logger.Info(fmt.Sprintf("Performing backup '%d'", backupNumber))
	podName := bar.GetJenkinsMasterPodName()
	command := jenkins.Spec.Backup.Action.Exec.Command
	command = append(command, fmt.Sprintf("%d", backupNumber))
	_, _, err := bar.Exec(podName, jenkins.Spec.Backup.ContainerName, command)

	if err == nil {
		bar.logger.V(log.VDebug).Info(fmt.Sprintf("Backup completed '%d', updating status", backupNumber))
		if jenkins.Status.RestoredBackup == 0 {
			jenkins.Status.RestoredBackup = backupNumber
		}
		jenkins.Status.LastBackup = backupNumber
		jenkins.Status.PendingBackup = backupNumber
		jenkins.Status.BackupDoneBeforePodDeletion = setBackupDoneBeforePodDeletion
		return bar.Client.Update(context.TODO(), jenkins)
	}

	return err
}

func triggerBackup(ticker *time.Ticker, k8sClient k8s.Client, logger logr.Logger, namespace, name string) {
	for range ticker.C {
		jenkins := &v1alpha2.Jenkins{}
		err := k8sClient.Get(context.TODO(), types.NamespacedName{Namespace: namespace, Name: name}, jenkins)
		if err != nil && apierrors.IsNotFound(err) {
			triggers.stop(logger, namespace, name)
			return // abort
		} else if err != nil {
			logger.V(log.VWarn).Info(fmt.Sprintf("backup trigger, error when fetching CR: %s", err))
		}
		if jenkins.Status.LastBackup == jenkins.Status.PendingBackup {
			jenkins.Status.PendingBackup++
			err = k8sClient.Update(context.TODO(), jenkins)
			if err != nil {
				logger.V(log.VWarn).Info(fmt.Sprintf("backup trigger, error when updating CR: %s", err))
			}
		}
	}
}

// EnsureBackupTrigger creates or update trigger which update CR to make backup
func (bar *BackupAndRestore) EnsureBackupTrigger() error {
	trigger, found := triggers.get(bar.Configuration.Jenkins.Namespace, bar.Configuration.Jenkins.Name)

	isBackupConfigured := len(bar.Configuration.Jenkins.Spec.Backup.ContainerName) > 0 && bar.Configuration.Jenkins.Spec.Backup.Interval > 0
	if found && !isBackupConfigured {
		bar.StopBackupTrigger()
		return nil
	}

	// configured backup has no trigger
	if !found && isBackupConfigured {
		bar.startBackupTrigger()
		return nil
	}

	if found && isBackupConfigured && bar.Configuration.Jenkins.Spec.Backup.Interval != trigger.interval {
		bar.StopBackupTrigger()
		bar.startBackupTrigger()
	}

	return nil
}

// StopBackupTrigger stops trigger which update CR to make backup
func (bar *BackupAndRestore) StopBackupTrigger() {
	triggers.stop(bar.logger, bar.Configuration.Jenkins.Namespace, bar.Configuration.Jenkins.Name)
}

// IsBackupTriggerEnabled returns true if the backup trigger is enabled
func (bar *BackupAndRestore) IsBackupTriggerEnabled() bool {
	_, enabled := triggers.get(bar.Configuration.Jenkins.Namespace, bar.Configuration.Jenkins.Name)
	return enabled
}

func (bar *BackupAndRestore) startBackupTrigger() {
	bar.logger.Info("Starting backup trigger")
	ticker := time.NewTicker(time.Duration(bar.Configuration.Jenkins.Spec.Backup.Interval) * time.Second)
	triggers.add(bar.Configuration.Jenkins.Namespace, bar.Configuration.Jenkins.Name, backupTrigger{
		interval: bar.Configuration.Jenkins.Spec.Backup.Interval,
		ticker:   ticker,
	})
	go triggerBackup(ticker, bar.Client, bar.logger, bar.Configuration.Jenkins.Namespace, bar.Configuration.Jenkins.Name)
}
