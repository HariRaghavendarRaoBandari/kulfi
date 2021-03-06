#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <stdio.h>
#include <ctype.h>
#include <time.h>
#include <math.h>
#include <netinet/in.h>
#include <resolv.h>
#include <netdb.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>

int stop = 0;

void sig_handler(int sig_num){
    stop = 1;
}

char * repeat_str(const char * s, int n) {
    size_t slen = strlen(s);
    char * dest = (char *)malloc(n*slen+1);

    int i; char * p;
    for ( i=0, p = dest; i < n; ++i, p += slen ) {
        memcpy(p, s, slen);
    }
    *p = '\0';
    return dest;
}

float poisson_interval(int total_num_flows, float time_interval){
    return -logf(1.0f - (float)random() / (RAND_MAX)) / total_num_flows * time_interval;
}

int name_to_ip(char* hostname , char* ip_addr)
{
    struct addrinfo hints, *res;
    struct in_addr addr;
    int err;

    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_INET;
    if( (err = getaddrinfo(hostname, NULL, &hints, &res)) != 0){
        fprintf(stderr, "getaddrinfo host: %s error: %d\n", hostname, err);
        return err;
    }

    addr = ((struct sockaddr_in *)(res->ai_addr))->sin_addr;

    strcpy(ip_addr, inet_ntoa(addr));
    freeaddrinfo(res);
    return 0;
}

void usage(){
    fprintf(stdout, "Usage:\n"
            "\t server [OPTION...]\n\n"
            "Options:\n"
            "\t-n\t<num_flows>\tnumber of flows to generate\n"
            "\t-s\t<host>\tserver address\n"
            "\t-p\t#\tserver port\n"
            "\t-l\t#\tlength of message to send\n");
}

int main(int argc, char* argv[]){
    // Set server details
    signal(SIGINT, sig_handler);
    int num_flows = 1;
    int scaled_to_time = 1;
    int server_port = 5000;
    char server_addr[32];
    char server_name[128];
    unsigned int sleep_time = 0;

    // Construct dummy data
    const char base[]="abcdefghijklmnopqrstuvwxyz0123456789";
    char *base100;
    char *copy_base;

    base100 = repeat_str(base, 100);
    base100[3600]='\0';

    copy_base = (char *)malloc(3601);
    strcpy(copy_base, base100);
    char read_buffer[256];
    struct timespec flow_start={0,0}, flow_end={0,0};

    // length of flow
    long int msg_len = 1000;

    int opt;

    memset(server_addr, 0, 32);
    memset(read_buffer, 0, 256);
    while ((opt = getopt (argc, argv, "hs:l:p:n:t:")) != -1){
        switch (opt)
        {
            case 'n':
                num_flows = atoi(optarg);
                break;
            case 'p':
                server_port = atoi(optarg);
                break;
            case 'l':
                msg_len = atol(optarg);
                break;
            case 't':
                scaled_to_time = atoi(optarg);
                break;
            case 's':
                strcpy(server_name, optarg);
                break;
            case 'h':
                usage();
                return 0;
            case '?':
                if (optopt == 's' || optopt == 'l' || optopt == 'p' || optopt == 'n'){
                    fprintf (stderr, "Option -%c requires an argument.\n", optopt);
                }
                else if (isprint (optopt)) {
                    fprintf (stderr, "Unknown option `-%c'.\n", optopt);
                }
                else {
                    fprintf (stderr, "Unknown option character `\\x%x'.\n", optopt);
                }
                return 1;
            default:
                abort ();
        }
    }

    if(name_to_ip(server_name, server_addr) != 0){
        fprintf(stderr, "Error in resolving server address\n");
        return 1;
    }
    int sockfd;
    struct sockaddr_in my_addr;

    int bytes_sent;
    long buffer_len = 0;
    long total_sent = 0;

    int * p_int;
    int err;
    msg_len = msg_len/num_flows;

    // Create socket
    sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if(sockfd == -1){
        printf("Error creating socket %d\n",errno);
        return 1;
    }


    // Set socket options
    p_int = (int*)malloc(sizeof(int));
    *p_int = 1;
    if( (setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, (char*)p_int, sizeof(int)) == -1 )||
            (setsockopt(sockfd, SOL_SOCKET, SO_KEEPALIVE, (char*)p_int, sizeof(int)) == -1 ) ){
        printf("Error setting socket options %d\n", errno);
        free(p_int);
        return 1;
    }
    free(p_int);

    // Set server details in socket
    my_addr.sin_family = AF_INET ;
    my_addr.sin_port = htons(server_port);

    memset(&(my_addr.sin_zero), 0, 8);
    my_addr.sin_addr.s_addr = inet_addr(server_addr);

    // Connect to server
    if(connect(sockfd, (struct sockaddr*)&my_addr, sizeof(my_addr)) == -1 ){
        if((err = errno) != EINPROGRESS){
            fprintf(stderr, "Error connecting socket %d %s\n", errno, server_addr);
            return -1;
        }
    }

    while(num_flows-- > 0){
        clock_gettime(CLOCK_MONOTONIC, &flow_start);
        total_sent = 0;
        strcpy(base100, copy_base);
        buffer_len = strlen(base100);
        // Send data
        while(total_sent < msg_len && !stop){
            /* Send blocks of base100
               Send remaining size data for the last block */
            if(msg_len - total_sent < 3600){
                base100[msg_len-total_sent] = '\0';
                buffer_len = msg_len - total_sent;
            }
            if( (bytes_sent =  send(sockfd, base100, buffer_len,0)) == -1){
                fprintf(stderr, "Error sending data %d\n", errno);
            }
            // printf("Sent bytes %d\n", bytes_sent);
            total_sent += bytes_sent;
        }
        sleep_time = (unsigned int)(1000000 * 0.5 * poisson_interval(num_flows, scaled_to_time));
        usleep(sleep_time);
    }
    // shutdown socket for writing
    shutdown(sockfd, SHUT_WR);

    buffer_len = read(sockfd, read_buffer, 256);
    if(buffer_len < 0){
        fprintf(stderr, "Error in reading from server\n");
    }
    // fprintf(stderr, "%s\n", read_buffer);
    close(sockfd);
    clock_gettime(CLOCK_MONOTONIC, &flow_end);
    fprintf(stdout, "%ld bytes\t%.6f sec\n", total_sent, ((double)flow_end.tv_sec + 1.0e-9*flow_end.tv_nsec) -
            ((double)flow_start.tv_sec + 1.0e-9*flow_start.tv_nsec));
    fflush(stdout);

    free(copy_base);
    free(base100);
    return 0;
}

