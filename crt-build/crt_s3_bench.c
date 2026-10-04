/* crt_s3_bench.c — minimal aws-c-s3 (CRT) PUT+GET round-trip harness.
 * Doubles as the seed for the chem_remote_s3.c CRT transport: crt_put_object / crt_get_object.
 * Usage: crt_s3_bench <region> <bucket> <key> <local_put_file> <local_get_file>
 * Times PUT then GET of the file, prints round-trip seconds. Uses default cred chain (instance role).
 */
#include <aws/s3/s3_client.h>
#include <aws/s3/s3.h>
#include <aws/auth/credentials.h>
#include <aws/io/event_loop.h>
#include <aws/io/host_resolver.h>
#include <aws/io/channel_bootstrap.h>
#include <aws/io/stream.h>
#include <aws/http/request_response.h>
#include <aws/common/condition_variable.h>
#include <aws/common/mutex.h>
#include <aws/common/string.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct wait_ctx { struct aws_mutex m; struct aws_condition_variable cv; bool done; int status; };
static bool is_done(void *a){ return ((struct wait_ctx*)a)->done; }
static void on_finish(struct aws_s3_meta_request *mr, const struct aws_s3_meta_request_result *res, void *user){
    (void)mr; struct wait_ctx *w=user;
    aws_mutex_lock(&w->m); w->done=true; w->status=res->error_code;
    aws_condition_variable_notify_all(&w->cv); aws_mutex_unlock(&w->m);
}
static void wait_reset(struct wait_ctx *w){ w->done=false; w->status=0; }
static int wait_finish(struct wait_ctx *w){
    aws_mutex_lock(&w->m);
    aws_condition_variable_wait_pred(&w->cv,&w->m,is_done,w);
    int s=w->status; aws_mutex_unlock(&w->m); return s;
}

static double now(){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec*1e-9; }

int main(int argc, char **argv){
    if(argc<6){ fprintf(stderr,"usage: %s region bucket key put_file get_file\n",argv[0]); return 2; }
    const char *region=argv[1], *bucket=argv[2], *key=argv[3], *putf=argv[4], *getf=argv[5];
    struct aws_allocator *alloc=aws_default_allocator();
    aws_s3_library_init(alloc);

    struct aws_event_loop_group *elg=aws_event_loop_group_new_default(alloc,0,NULL);
    struct aws_host_resolver_default_options ropt={.el_group=elg,.max_entries=16};
    struct aws_host_resolver *resolver=aws_host_resolver_new_default(alloc,&ropt);
    struct aws_client_bootstrap_options bopt={.event_loop_group=elg,.host_resolver=resolver};
    struct aws_client_bootstrap *boot=aws_client_bootstrap_new(alloc,&bopt);

    struct aws_credentials_provider_chain_default_options cpo; AWS_ZERO_STRUCT(cpo);
    cpo.bootstrap=boot;
    struct aws_credentials_provider *creds=aws_credentials_provider_new_chain_default(alloc,&cpo);

    struct aws_signing_config_aws scfg; AWS_ZERO_STRUCT(scfg);
    aws_s3_init_default_signing_config(&scfg, aws_byte_cursor_from_c_str(region), creds);
    scfg.flags.use_double_uri_encode=false;

    struct aws_s3_client_config ccfg; AWS_ZERO_STRUCT(ccfg);
    ccfg.client_bootstrap=boot;
    ccfg.region=aws_byte_cursor_from_c_str(region);
    ccfg.signing_config=&scfg;
    struct aws_s3_client *client=aws_s3_client_new(alloc,&ccfg);

    struct wait_ctx w; aws_mutex_init(&w.m); w.cv=(struct aws_condition_variable)AWS_CONDITION_VARIABLE_INIT;

    char host[512]; snprintf(host,sizeof host,"%s.s3.%s.amazonaws.com",bucket,region);
    char path[1024]; snprintf(path,sizeof path,"/%s",key);

    /* ---------- PUT ---------- */
    double t0=now();
    {
        struct aws_input_stream *body=aws_input_stream_new_from_file(alloc,putf);
        int64_t len=0; aws_input_stream_get_length(body,&len);
        struct aws_http_message *msg=aws_http_message_new_request(alloc);
        aws_http_message_set_request_method(msg,aws_byte_cursor_from_c_str("PUT"));
        aws_http_message_set_request_path(msg,aws_byte_cursor_from_c_str(path));
        struct aws_http_header hh={.name=aws_byte_cursor_from_c_str("Host"),.value=aws_byte_cursor_from_c_str(host)};
        aws_http_message_add_header(msg,hh);
        char clen[32]; snprintf(clen,sizeof clen,"%lld",(long long)len);
        struct aws_http_header ch={.name=aws_byte_cursor_from_c_str("Content-Length"),.value=aws_byte_cursor_from_c_str(clen)};
        aws_http_message_add_header(msg,ch);
        aws_http_message_set_body_stream(msg,body);
        struct aws_s3_meta_request_options o; AWS_ZERO_STRUCT(o);
        o.type=AWS_S3_META_REQUEST_TYPE_PUT_OBJECT; o.message=msg; o.finish_callback=on_finish; o.user_data=&w;
        wait_reset(&w);
        struct aws_s3_meta_request *mr=aws_s3_client_make_meta_request(client,&o);
        int s=wait_finish(&w);
        if(s){ fprintf(stderr,"PUT failed err=%d\n",s); return 1; }
        aws_s3_meta_request_release(mr); aws_http_message_release(msg); aws_input_stream_release(body);
    }
    double t1=now();
    /* ---------- GET ---------- */
    {
        FILE *of=fopen(getf,"wb"); (void)of; /* the CRT delivers body via callback; for a bench we just discard-to-file via a body callback is more code; here we time the meta-request only */
        struct aws_http_message *msg=aws_http_message_new_request(alloc);
        aws_http_message_set_request_method(msg,aws_byte_cursor_from_c_str("GET"));
        aws_http_message_set_request_path(msg,aws_byte_cursor_from_c_str(path));
        struct aws_http_header hh={.name=aws_byte_cursor_from_c_str("Host"),.value=aws_byte_cursor_from_c_str(host)};
        aws_http_message_add_header(msg,hh);
        struct aws_s3_meta_request_options o; AWS_ZERO_STRUCT(o);
        o.type=AWS_S3_META_REQUEST_TYPE_GET_OBJECT; o.message=msg; o.finish_callback=on_finish; o.user_data=&w;
        wait_reset(&w);
        struct aws_s3_meta_request *mr=aws_s3_client_make_meta_request(client,&o);
        int s=wait_finish(&w);
        if(s){ fprintf(stderr,"GET failed err=%d\n",s); return 1; }
        aws_s3_meta_request_release(mr); aws_http_message_release(msg);
        if(of) fclose(of);
    }
    double t2=now();
    printf("CRT_PUT=%.2fs CRT_GET=%.2fs CRT_ROUNDTRIP=%.2fs\n", t1-t0, t2-t1, t2-t0);

    aws_s3_client_release(client);
    aws_credentials_provider_release(creds);
    aws_client_bootstrap_release(boot);
    aws_host_resolver_release(resolver);
    aws_event_loop_group_release(elg);
    aws_mutex_clean_up(&w.m);
    aws_s3_library_clean_up();
    return 0;
}
