package distsys

// Implements the etcd global state management API.
//
// Currently, PGo manages global state in a distributed environment by using the
// `etcd' key-value store. The functions defined here wrap that behaviour by providing
// a get/set interface so that if ever the way that we store global variables change,
// our API (and the code generated by the compiler) may hopefully stay the same.
//
// Usage:
//
// 	import (
// 		"fmt"
// 		"pgo/distsys"
// 	)
//
// 	config := &Config{
// 		Endpoints: []string{"10.0.0.1:1234", "10.0.0.2:1234"},
// 		Timeout: 3,
// 	}
// 	state, err := distsys.InitEtcdState(config)
// 	if err != nil {
// 		// handle error
// 	}
//
// 	state.Set("project", "PGo")
// 	val := state.GetString("project")
// 	fmt.Printf("project value has value: %s\n", val) // project has value: PGo
//
// 	// Integers are also supported
// 	state.Set("count", 42)
// 	count := state.Get("count")
// 	fmt.Printf("count has value: %d\n", count) // count has value: 42
//
// 	// so are collections
// 	col := []string{"1", "2", "3"}
// 	state.Set("collection", col)
// 	col = state.GetStringCollection("collection")

// Implementation Details
//
// Global variables are stored in `etcd' as name => hex-encoded string of a gob.
//
// This representation is internal and applications need not know about it.

import (
	"bytes"
	"context"
	"encoding/gob"
	"encoding/hex"
	"fmt"
	"time"

	etcd "github.com/coreos/etcd/client"
)

// declares the types of global variables supported by PGo at the moment.
const (
	LOCK_NAMESPACE = "/locks/"
)

// A reference to our global state, created via +InitEtcdState+. Used in the
// generated Go code to set and get the values of global variables.
type EtcdState struct {
	*ProcessInitialization
	c  etcd.Client
	kv etcd.KeysAPI
}

// Initializes centralized global state management.
//
// The only currently supported global state management is the `centralized'
// strategy - that is, every request to global state is sent to the same server
// (or collection of servers).
//
// Returns a reference to `distsys.EtcdState' on success. Fails if we
// cannot establish a connection to the etcd cluster.
func NewEtcdState(endpoints []string, timeout int, peers []string, self, coordinator string, initValues map[string]interface{}) (*EtcdState, error) {
	c, err := etcd.New(etcd.Config{
		Endpoints:               endpoints,
		HeaderTimeoutPerRequest: time.Duration(timeout) * time.Second,
	})
	if err != nil {
		return nil, err
	}

	ret := &EtcdState{
		NewProcessInitialization(peers, self, coordinator),
		c,
		etcd.NewKeysAPI(c),
	}

	if ret.isCoordinator() && len(initValues) > 0 {
		for name, val := range initValues {
			ret.Set(name, val)
		}
	}

	if err := ret.Init(); err != nil {
		return nil, err
	}

	return ret, nil
}

// Sets variable `name' to a given `value'. Contacts the global variable server
// *synchronously*
func (self *EtcdState) Set(name string, value interface{}) {
	buffer := bytes.Buffer{}
	encoder := gob.NewEncoder(&buffer)
	err := encoder.Encode(value)
	if err != nil {
		panic(fmt.Sprintf("Unable to GobEncode %v, err = %s", value, err.Error()))
	}
	s := hex.EncodeToString(buffer.Bytes())
	key := prepareKey(name)
	_, err = self.kv.Set(context.Background(), key, s, nil)
	if err != nil {
		panic(fmt.Sprintf("Unable to set %s to %s, err = %s", key, s, err))
	}
}

// indicates whether a variable with the given name was previously set.
// Caller must hold a lock before invoking this function if behavior following
// its return lies within a critical section
func (self *EtcdState) Exists(name string) bool {
	_, err := self.kv.Get(context.Background(), prepareKey(name), nil)
	if err != nil {
		etcdErr := err.(etcd.Error)
		if etcdErr.Code == etcd.ErrorCodeKeyNotFound {
			return false
		}

		panic(err)
	}

	return true
}

// Gets the value associated with a variable with the given `name'. Contacts
// the global variable server *synchronously*.
func (self *EtcdState) Get(name string, variable interface{}) interface{} {
	key := prepareKey(name)
	response, err := self.kv.Get(context.Background(), key, nil)
	if err != nil {
		panic(fmt.Sprintf("Unable to get %s, err = %s", key, err.Error()))
	}

	buffer, err := hex.DecodeString(response.Node.Value)
	if err != nil {
		panic(fmt.Sprintf("Unable to hex.Decode %s, err = %s", response.Node.Value, err.Error()))
	}

	decoder := gob.NewDecoder(bytes.NewReader(buffer))
	err = decoder.Decode(variable)
	if err != nil {
		panic(fmt.Sprintf("Unable to GobDecode %v, err = %s", buffer, err.Error()))
	}

	return variable
}

func (self *EtcdState) Lock(who, which string) {
	key := prepareLock(which)
	for {
		_, err := self.kv.Create(context.Background(), key, who)
		etcdErr, ok := err.(etcd.Error)
		if err == nil {
			return
		}
		if !ok || etcdErr.Code != etcd.ErrorCodeNodeExist {
			panic(err)
		}
	}
}

func (self *EtcdState) Unlock(who, which string) {
	_, err := self.kv.Delete(context.Background(), prepareLock(which), &etcd.DeleteOptions{
		PrevValue: who,
	})
	if err != nil {
		panic(err)
	}
}

// given a key k, this method transforms it to the format expected by `etcd'
func prepareKey(k string) string {
	return "/" + k
}

// given a lock k, this method transforms it to the format expected by `etcd'
func prepareLock(k string) string {
	return LOCK_NAMESPACE + k
}
