package main

#Config: {
	metadata: {
		name:      string
		namespace: string
	}
	moduleVersion: string
	kubeVersion:   string
	replicas:      int & >=1 | *1
	image:         string | *"registry.example/smoke:1.0.0"
}

values: #Config

timoni: {
	apiVersion: "v1alpha1"

	instance: {
		config: values
		config: {
			metadata: {
				name:      string @tag(name)
				namespace: string @tag(namespace)
			}
			moduleVersion: string @tag(mv, var=moduleVersion)
			kubeVersion:   string @tag(kv, var=kubeVersion)
		}

		objects: deployment: {
			apiVersion: "apps/v1"
			kind:       "Deployment"
			metadata: {
				name:      config.metadata.name
				namespace: config.metadata.namespace
				labels: "app.kubernetes.io/version": config.moduleVersion
			}
			spec: {
				replicas: config.replicas
				selector: matchLabels: app: config.metadata.name
				template: {
					metadata: labels: app: config.metadata.name
					spec: containers: [{
						name:  "app"
						image: config.image
					}]
				}
			}
		}
	}

	apply: app: [for obj in instance.objects {obj}]
}
