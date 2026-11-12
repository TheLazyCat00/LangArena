#include "binding.h"
#include "vendor/yyjson.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <regex.h>
static void die(const char *s) {fprintf(stderr,"LangArena: %s\n",s);exit(2);}
static void *alloc(size_t n) {void *p=malloc(n?n:1);if(!p)die("out of memory");return p;}
static zane_bytes copy(const char *s,size_t n) {uint8_t *p=zane_bytes_alloc(n);if(n)memcpy(p,s,n);return (zane_bytes){p,n};}
zane_bytes arena_base64_encode(zane_bytes input) {static const char table[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";size_t n=(input.size+2)/3*4;uint8_t *p=zane_bytes_alloc(n);const uint8_t *s=input.data;for(size_t i=0,j=0;i<input.size;i+=3) {uint32_t v=(uint32_t)s[i]<<16;if(i+1<input.size)v|=(uint32_t)s[i+1]<<8;if(i+2<input.size)v|=s[i+2];p[j++]=table[(v>>18)&63];p[j++]=table[(v>>12)&63];p[j++]=i+1<input.size?table[(v>>6)&63]:'=';p[j++]=i+2<input.size?table[v&63]:'=';}return (zane_bytes){p,n};}
static int decode(uint8_t c) {if(c>='A'&&c<='Z')return c-'A';if(c>='a'&&c<='z')return c-'a'+26;if(c>='0'&&c<='9')return c-'0'+52;if(c=='+')return 62;if(c=='/')return 63;return -1;}
zane_bytes arena_base64_decode(zane_bytes input) {if(input.size%4)die("invalid base64 length");if(!input.size)return copy("",0);const uint8_t *s=input.data;size_t n=input.size/4*3;if(s[input.size-1]=='=')n--;if(s[input.size-2]=='=')n--;uint8_t *p=zane_bytes_alloc(n);size_t j=0;for(size_t i=0;i<input.size;i+=4) {uint32_t v=0;for(int k=0;k<4;k++) {int d=s[i+k]=='='?0:decode(s[i+k]);if(d<0)die("invalid base64 byte");v=(v<<6)|(unsigned)d;}if(j<n)p[j++]=(uint8_t)(v>>16);if(j<n)p[j++]=(uint8_t)(v>>8);if(j<n)p[j++]=(uint8_t)v;}return (zane_bytes){p,n};}
struct arena_json {yyjson_mut_doc *mutable;yyjson_doc *parsed;yyjson_mut_val *coords;};
arena_json *arena_json_new(void) {arena_json *j=calloc(1,sizeof(*j));if(!j)die("out of memory");j->mutable=yyjson_mut_doc_new(NULL);if(!j->mutable)die("out of memory");yyjson_mut_val *root=yyjson_mut_obj(j->mutable);yyjson_mut_doc_set_root(j->mutable,root);j->coords=yyjson_mut_arr(j->mutable);yyjson_mut_obj_add_val(j->mutable,root,"coordinates",j->coords);yyjson_mut_obj_add_str(j->mutable,root,"info","some info");return j;}
arena_json *arena_json_parse(zane_bytes text) {arena_json *j=calloc(1,sizeof(*j));if(!j)die("out of memory");j->parsed=yyjson_read((const char *)text.data,text.size,0);if(!j->parsed)die("invalid coordinate JSON");return j;}
void arena_json_free(arena_json *j) {if(j->mutable)yyjson_mut_doc_free(j->mutable);if(j->parsed)yyjson_doc_free(j->parsed);free(j);}
void arena_json_add(arena_json *j,double x,double y,double z,zane_bytes name) {yyjson_mut_doc *d=j->mutable;yyjson_mut_val *v=yyjson_mut_obj(d);yyjson_mut_obj_add_real(d,v,"x",x);yyjson_mut_obj_add_real(d,v,"y",y);yyjson_mut_obj_add_real(d,v,"z",z);yyjson_mut_obj_add_strncpy(d,v,"name",(const char *)name.data,name.size);yyjson_mut_val *opts=yyjson_mut_obj(d),*tuple=yyjson_mut_arr(d);yyjson_mut_arr_add_int(d,tuple,1);yyjson_mut_arr_add_bool(d,tuple,true);yyjson_mut_obj_add_val(d,opts,"1",tuple);yyjson_mut_obj_add_val(d,v,"opts",opts);yyjson_mut_arr_append(j->coords,v);}
zane_bytes arena_json_string(const arena_json *j) {size_t n=0;char *s=yyjson_mut_write(j->mutable,0,&n);if(!s)die("JSON serialization failed");zane_bytes out=copy(s,n);free(s);return out;}
int64_t arena_json_count(const arena_json *j) {return (int64_t)yyjson_arr_size(yyjson_obj_get(yyjson_doc_get_root(j->parsed),"coordinates"));}
double arena_json_get(const arena_json *j,int64_t index,int64_t axis) {const char *keys[]={"x","y","z"};if(index<1||index>arena_json_count(j)||axis<0||axis>2)die("JSON index out of bounds");yyjson_val *coords=yyjson_obj_get(yyjson_doc_get_root(j->parsed),"coordinates");return yyjson_get_num(yyjson_obj_get(yyjson_arr_get(coords,(size_t)(index-1)),keys[axis]));}
struct arena_csv {double *values;size_t rows;};
arena_csv *arena_csv_parse(zane_bytes text) {arena_csv *out=calloc(1,sizeof(*out));if(!out)die("out of memory");size_t capacity=16;out->values=alloc(capacity*3*sizeof(double));char *field=alloc(text.size+1);size_t used=0,col=0;double values[3]={0};bool quoted=false;const char *s=(const char *)text.data;
for(size_t i=0;i<=text.size;i++) {char c=i<text.size?s[i]:'\n';if(c=='"') {if(quoted&&i+1<text.size&&s[i+1]=='"') {field[used++]='"';i++;}else quoted=!quoted;}else if(!quoted&&(c==','||c=='\n')) {field[used]='\0';if(col==1)values[0]=strtod(field,NULL);if(col==3)values[2]=strtod(field,NULL);if(col==5)values[1]=strtod(field,NULL);used=0;col++;if(c=='\n') {if(col==6) {if(out->rows==capacity) {capacity*=2;double *p=realloc(out->values,capacity*3*sizeof(double));if(!p)die("out of memory");out->values=p;}memcpy(out->values+out->rows*3,values,sizeof(values));out->rows++;}else if(col>1)die("invalid CSV row");col=0;}}else field[used++]=c;}if(quoted)die("unterminated CSV quote");free(field);return out;}
void arena_csv_free(arena_csv *csv) {free(csv->values);free(csv);}
int64_t arena_csv_count(const arena_csv *csv) {return (int64_t)csv->rows;}
double arena_csv_get(const arena_csv *csv,int64_t row,int64_t column) {if(row<1||(uint64_t)row>csv->rows||column<0||column>2)die("CSV index out of bounds");return csv->values[(row-1)*3+column];}
struct arena_regex {regex_t compiled;};
arena_regex *arena_regex_new(const char *pattern,bool insensitive) {arena_regex *r=alloc(sizeof(*r));if(regcomp(&r->compiled,pattern,REG_EXTENDED|(insensitive?REG_ICASE:0)))die("invalid regex");return r;}
void arena_regex_free(arena_regex *r) {regfree(&r->compiled);free(r);}
int64_t arena_regex_count(const arena_regex *r,const char *text) {int64_t count=0;regmatch_t m;while(*text&&regexec(&r->compiled,text,1,&m,0)==0) {count++;text+=m.rm_eo?m.rm_eo:1;}return count;}
int64_t arena_regex_find(const arena_regex *r,const char *text,int64_t offset,bool end) {size_t n=strlen(text);if(offset<1||(uint64_t)(offset-1)>n)return 0;regmatch_t m;if(regexec(&r->compiled,text+offset-1,1,&m,0))return 0;return offset+(end?m.rm_eo:m.rm_so);}
