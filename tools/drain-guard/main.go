// Command drain-guard keeps node drains from taking a MariaDB primary down (PLAN.md phase 7).
//
// It runs as a controller (moves the primary off a draining node) and as a validating
// webhook for pods/eviction (refuses the primary's eviction with HTTP 429 until the move
// is done, which every drain tool retries). Both run in one binary with leader election;
// the webhook serves from every replica.
package main

import (
	"context"
	"flag"
	"os"
	"strings"
	"time"

	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/controller-runtime/pkg/webhook"
)

// defaultDrainKeys are the taints that mean "this node is going away" (PLAN.md phase 7,
// step 2). Provider keys are added with --drain-taint-keys.
var defaultDrainKeys = []string{
	"node.kubernetes.io/unschedulable",
	"ToBeDeletedByClusterAutoscaler",
	"karpenter.sh/disrupted",
}

func main() {
	var (
		metricsAddr   string
		probeAddr     string
		webhookPort   int
		certDir       string
		leaderElect   bool
		extraTaintKey string
		resync        time.Duration
	)
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "address of the Prometheus endpoint")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "address of the health endpoints")
	flag.IntVar(&webhookPort, "webhook-port", 9443, "port of the eviction webhook")
	flag.StringVar(&certDir, "cert-dir", "/tls", "directory with tls.crt and tls.key of the webhook")
	flag.BoolVar(&leaderElect, "leader-elect", true, "run a single active controller")
	flag.StringVar(&extraTaintKey, "drain-taint-keys", "", "comma-separated extra taint keys that mark a draining node")
	flag.DurationVar(&resync, "resync", 30*time.Second, "how often every instance is checked")
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&zap.Options{})))
	log := ctrl.Log.WithName("drain-guard")

	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		log.Error(err, "building the scheme")
		os.Exit(1)
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: metricsAddr},
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         leaderElect,
		LeaderElectionID:       "drain-guard.dbaas.local",
		WebhookServer:          webhook.NewServer(webhook.Options{Port: webhookPort, CertDir: certDir}),
	})
	if err != nil {
		log.Error(err, "creating the manager")
		os.Exit(1)
	}

	keys := map[string]bool{}
	for _, k := range defaultDrainKeys {
		keys[k] = true
	}
	for _, k := range strings.Split(extraTaintKey, ",") {
		if k = strings.TrimSpace(k); k != "" {
			keys[k] = true
		}
	}

	m := newGuardMetrics(metrics.Registry)
	guard := NewGuard(mgr.GetClient(), mgr.GetAPIReader(), keys, m, mgr.GetEventRecorderFor("drain-guard"))

	mgr.GetWebhookServer().Register("/validate-eviction", &webhook.Admission{
		Handler: &evictionWebhook{g: guard},
	})

	if err := mgr.Add(manager.RunnableFunc(func(ctx context.Context) error {
		t := time.NewTicker(resync)
		defer t.Stop()
		for {
			if err := guard.Reconcile(ctx); err != nil {
				log.Error(err, "reconciling the instances")
			}
			select {
			case <-ctx.Done():
				return nil
			case <-t.C:
			}
		}
	})); err != nil {
		log.Error(err, "adding the reconcile loop")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("ping", healthz.Ping); err != nil {
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("webhook", mgr.GetWebhookServer().StartedChecker()); err != nil {
		os.Exit(1)
	}

	log.Info("drain-guard starting", "drainTaintKeys", len(keys), "resync", resync.String())
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		log.Error(err, "running the manager")
		os.Exit(1)
	}
}
