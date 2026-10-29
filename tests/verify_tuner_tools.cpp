#include "tuner_tools.h"
#include <cstdio>
#include <cstdlib>
using namespace NAMRig::Tuning;
static int checks;
#define CHECK(x) do { ++checks; if (!(x)) { std::fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);std::exit(1); } } while(0)
static void settle(Model& m,double pitch,double start=0,double confidence=.99,double db=-18) {
  for (int i=0;i<12;++i)m.update(start+i*.05,pitch+(i%2?.002:-.002),confidence,db);
}
int main() {
  CHECK(std::abs(frequency(69)-440)<1e-9);
  CHECK(parseNote("C#4")==61 && parseNote("Db4")==61 && parseNote("b1")==35);
  CHECK(parseNote("B0")==23 && parseNote("F6")==89);
  for(const char* bad:{"A0","F#6","E","#E2","E2x","C#","H2","E-1"})CHECK(parseNote(bad)==-1);
  CHECK(factoryTunings()[6].notes.size()==7 && factoryTunings()[8].notes.size()==8);
  for(const auto& p:factoryTunings())for(int n:p.notes)CHECK(frequency(n)>=30 && frequency(n)<=1400);
  Model model;settle(model,40);CHECK(model.status==Status::Stable);
  model.update(.65,40,.7,-18);CHECK(model.status==Status::Weak);
  settle(model,40,1,.99,-48);CHECK(model.status==Status::Fading);
  model.update(2,-1,0,-120);CHECK(model.status==Status::Listening);
  model.clearHistory();for(int i=0;i<20;++i)model.update(3+i*.05,40+(i%2?.06:-.06),.99,-18);
  CHECK(model.status==Status::Settling);
  model.strings={69};model.locked=0;model.setReference(442);settle(model,69,5);
  CHECK(std::abs(model.cents-100*(69-referenceOffset(442)-69))<.21);
  CHECK(model.status==Status::Stable);
  model.setReference(440);CHECK(model.history.empty() && !model.hasBaseline);
  model.locked=-1;settle(model,40.02,6);CHECK(model.captureBaseline());
  CHECK(model.status!=Status::Stable); // Cannot re-use the open-string sample as a fret measurement.
  settle(model,52.09,7);CHECK(model.captureFretted());CHECK(std::abs(model.intonationCents()-7)<.41);
  model.resetIntonation();model.harmonicBaseline=true;settle(model,52.01,8);CHECK(model.captureBaseline());
  settle(model,51.98,9);CHECK(model.captureFretted());CHECK(std::abs(model.intonationCents()+3)<.41);
  model.resetIntonation();model.harmonicBaseline=false;settle(model,40,10);CHECK(model.captureBaseline());
  settle(model,54,11);CHECK(!model.captureFretted());
  model.setReference(440);CHECK(!model.hasBaseline && !model.hasComparison);
  for(int i=0;i<500;++i)model.update(20+i*.05,40,.99,-18);
  CHECK(model.history.size()<=201);
  model.update(46,41,.99,-18);CHECK(model.history.size()==1 && model.status==Status::Settling);
  model.update(47,std::numeric_limits<double>::quiet_NaN(),1,-18);CHECK(model.pitch<0);
  std::printf("PASS: tuner tools (%d checks): targets, calibration, stability, intonation and history\n",checks);
}
