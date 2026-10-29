/* Exercise the built engine using the existing black-box host. */
#define main existing_tuner_regression_main
#include "verify_tuner.c"
#undef main
#include <lv2/atom/forge.h>
#define TONE "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-tuner-reference-tone"
#define GAIN "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-tuner-reference-gain"
static void command(Host* host,float hz,float gain,int send) {
  LV2_Atom_Forge forge;lv2_atom_forge_init(&forge,&host->map);
  lv2_atom_forge_set_buffer(&forge,host->control.bytes,kAtom);
  LV2_Atom_Forge_Frame seq;lv2_atom_forge_sequence_head(&forge,&seq,0);
  if(send)for(int which=0;which<2;++which) {
    LV2_Atom_Forge_Frame object;lv2_atom_forge_frame_time(&forge,0);
    lv2_atom_forge_object(&forge,&object,0,mapUri(NULL,LV2_PATCH__Set));
    lv2_atom_forge_key(&forge,mapUri(NULL,LV2_PATCH__property));lv2_atom_forge_urid(&forge,mapUri(NULL,which?TONE:GAIN));
    lv2_atom_forge_key(&forge,mapUri(NULL,LV2_PATCH__value));lv2_atom_forge_float(&forge,which?hz:gain);
    lv2_atom_forge_pop(&forge,&object);
  }
  lv2_atom_forge_pop(&forge,&seq);
}
static double silenceWithTone(Host* host,double seconds,float hz,int renewal) {
  double energy=0;uint64_t samples=0;int crosses=0,first=-1,last=-1;float prior=0;
  int count=(int)llround(seconds*host->rate);
  for(int done=0;done<count;) {
    uint32_t n=(uint32_t)fmin(host->block,count-done);
    memset(host->input,0,n*sizeof(float));
    command(host,hz,.0316228f,done==0||renewal);
    ((LV2_Atom_Sequence*)host->notify.bytes)->atom.size=kAtom-sizeof(LV2_Atom);
    host->descriptor->run(host->instance,n);
    for(uint32_t i=0;i<n;++i) {
      if(fabs(host->output[i]-host->right[i])>1e-7)host->healthy=0;
      float value=host->output[i];
      if(done+(int)i>count/2) {
        energy+=value*value;++samples;
        if(prior<=0&&value>0){if(first<0)first=done+i;last=done+i;++crosses;}
      }
      prior=value;
    }
    done+=n;
  }
  if(renewal&&hz>0&&host->ctl[kEnable]>=.5f)check(crosses>2&&fabs((crosses-1)*host->rate/(last-first)-hz)<1,"reference tone frequency %.1f Hz",hz);
  return samples?sqrt(energy/samples):0;
}
int main(int argc,char**argv) {
  if(argc!=2)return 2;
  void* library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!library){fprintf(stderr,"%s\n",dlerror());return 2;}
  const LV2_Descriptor*(*descriptor)(uint32_t)=dlsym(library,"lv2_descriptor");if(!descriptor)return 2;
  Host* host=calloc(1,sizeof(Host));if(!host)return 2;
  const double frequencies[]={30.868,36.708,41.203,46.249};
  for(int rate=0;rate<2;++rate)for(int i=0;i<4;++i) {
    if(!openHost(host,descriptor(0),rate?96000:48000,64))return 2;
    Signal signal={steady,frequencies[i],0,.25,0};double note=69+12*log2(frequencies[i]/440);
    Measurement m=feed(host,&signal,.85,.65,note);
    check(accurate(m,5),"low string %.3f Hz at %.0f Hz: error %.2fc missing %u",frequencies[i],host->rate,m.maxError,m.missing);
    closeHost(host);
  }
  if(!openHost(host,descriptor(0),48000,64))return 2;
  host->ctl[5]=-80; // Muted guitar must not mute the explicitly enabled reference.
  double rms=silenceWithTone(host,.30,440,1);
  check(fabs(rms-.0316228/sqrt(2))<.002,"audible low-level tone with guitar muted: RMS %.5f",rms);
  rms=silenceWithTone(host,2.0,440,0);
  check(rms<.0002,"tone lease expires without UI renewal: RMS %.6f",rms);
  silenceWithTone(host,.25,82.407,1);
  rms=silenceWithTone(host,.25,0,0);
  check(rms<.00001,"explicit stop fades to silence: RMS %.7f",rms);
  silenceWithTone(host,.15,440,1);host->ctl[kEnable]=0;
  rms=silenceWithTone(host,.25,440,1);
  check(rms<.00001,"tuner bypass stops reference even if commands are renewed");
  check(host->healthy,"reference is identical in left and right channels");
  closeHost(host);free(host);dlclose(library);
  printf("%s: tuner tools DSP (%d checks, %d failures)\n",fails?"FAIL":"PASS",checks,fails);
  return fails?1:0;
}
