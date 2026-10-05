package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"vpn-tunnel/internal/web"
)

func main() {
	role := flag.String("role", "iran", "Server role: iran or kharej")
	port := flag.Int("port", 8080, "HTTP server port")
	iranIP := flag.String("iran-ip", "", "Iran server IP (required for iran role)")
	iranPort := flag.Int("iran-port", 22, "Iran server SSH port")
	kharejIP := flag.String("kharej-ip", "", "Kharej server IP (required for kharej role)")
	kharejPort := flag.Int("kharej-port", 22, "Kharej server SSH port")
	sshUser := flag.String("ssh-user", "root", "SSH username")
	flag.Parse()

	if *role != "iran" && *role != "kharej" {
		log.Fatal("Role must be 'iran' or 'kharej'")
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("Shutting down...")
		cancel()
	}()

	server := web.NewServer(*role, *port)

	if *role == "iran" {
		if *iranIP == "" {
			log.Fatal("Iran IP is required for iran role (-iran-ip)")
		}
		server.SetIranConfig(*iranIP, *iranPort, *sshUser)
	} else {
		if *kharejIP == "" {
			log.Fatal("Kharej IP is required for kharej role (-kharej-ip)")
		}
		server.SetKharejConfig(*kharejIP, *kharejPort)
	}

	go func() {
		if err := server.Start(ctx); err != nil && err != http.ErrServerClosed {
			log.Printf("Server error: %v", err)
		}
	}()

	<-ctx.Done()
	time.Sleep(500 * time.Millisecond)
	fmt.Println("Server stopped")
}