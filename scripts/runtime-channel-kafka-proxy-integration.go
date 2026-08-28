package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/IBM/sarama"
)

func isOwnedKafkaTopic(topic string) bool {
	const prefix = "runtime.restart.acceptance."
	if !strings.HasPrefix(topic, prefix) || len(topic) != len(prefix)+64 {
		return false
	}
	for _, char := range topic[len(prefix):] {
		if !strings.ContainsRune("0123456789abcdef", char) {
			return false
		}
	}
	return true
}

func main() {
	broker := flag.String("broker", "", "Kafka bootstrap proxy host:port")
	topic := flag.String("topic", "", "unique harness-owned Kafka topic")
	correlation := flag.String("correlation", "", "unique rpc- correlation")
	flag.Parse()
	if *broker == "" || !isOwnedKafkaTopic(*topic) || !strings.HasPrefix(*correlation, "rpc-") {
		fmt.Fprintln(os.Stderr, "broker, owner-derived topic, and rpc- correlation are required")
		os.Exit(2)
	}

	config := sarama.NewConfig()
	config.Version = sarama.DefaultVersion
	config.ClientID = "runtime-channel-restart-proxy-integration"
	config.Net.DialTimeout = 5 * time.Second
	config.Net.ReadTimeout = 15 * time.Second
	config.Net.WriteTimeout = 5 * time.Second
	config.Producer.Return.Successes = true
	config.Producer.RequiredAcks = sarama.WaitForLocal
	producer, err := sarama.NewSyncProducer([]string{*broker}, config)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create Sarama producer: %v\n", err)
		os.Exit(1)
	}
	defer producer.Close()

	payload, err := json.Marshal(map[string]any{
		"schema":         1,
		"source":         "runtime-channel-restart-proxy-integration",
		"correlation_id": *correlation,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "encode payload: %v\n", err)
		os.Exit(1)
	}
	partition, offset, err := producer.SendMessage(&sarama.ProducerMessage{
		Topic: *topic,
		Key:   sarama.StringEncoder(*correlation),
		Value: sarama.ByteEncoder(payload),
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "publish through proxy: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("sarama_proxy_publish=PASS correlation=%s partition=%d offset=%d\n", *correlation, partition, offset)
}
