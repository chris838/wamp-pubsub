from autobahn.twisted.wamp import ApplicationSession, ApplicationRunner
from autobahn.twisted.util import sleep
from twisted.internet.defer import inlineCallbacks


class MyPublisher(ApplicationSession):

   def onJoin(self, details):

      print("Session ready. Publishing test chat")
      self.publish(u'com.zzish.testroom', {"nickname":"some user","text":"some message"} )

if __name__ == '__main__':
   runner = ApplicationRunner(url = u"ws://localhost:8080/ws", realm = u"realm1")
   runner.run(MyPublisher)
